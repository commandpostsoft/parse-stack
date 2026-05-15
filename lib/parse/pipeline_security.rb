# encoding: UTF-8
# frozen_string_literal: true

module Parse
  # Canonical security validator for MongoDB aggregation pipelines and
  # filter hashes that the SDK forwards to the driver or to Parse Server.
  #
  # Previously the codebase had three different validators with three
  # different rule sets:
  #
  # - `Parse::Agent::PipelineValidator` — strict allowlist for the Agent
  #   (read-only paths only)
  # - `Parse::Query#validate_pipeline!` — outer-stage-only denylist
  # - `Parse::MongoDB.assert_no_denied_operators!` — recursive denylist of
  #   server-side JS operators
  #
  # `Parse::AtlasSearch.convert_filter_for_mongodb` was a complete
  # passthrough that bypassed all three. A user-supplied filter containing
  # `$where`/`$expr`/`$function`/`$regex` was injected straight into the
  # pipeline `$match` stage, bypassing every existing constraint guard.
  #
  # This module consolidates the rules. Every entry point that forwards a
  # caller-supplied pipeline or filter to MongoDB now routes through one
  # of the two public methods here:
  #
  # - {validate_pipeline!} — strict mode (allowlist + size/depth caps).
  #   Used by `Parse::Agent` and by `Parse::Query#aggregate` for
  #   user-facing aggregation entry points.
  #
  # - {validate_filter!} — permissive mode (recursive denylist only).
  #   Used by `Parse::MongoDB.find/aggregate` and Atlas Search filter
  #   passthrough where the pipeline is constructed by SDK code but a
  #   user-controlled filter hash is interpolated. Refuses
  #   `$where`/`$function`/`$accumulator` and the data-mutating stages
  #   at any nesting depth.
  #
  # == Policy: allowlist top-level, denylist recursive
  #
  # Strict mode enforces {ALLOWED_STAGES} ONLY at the top-level stage
  # key — nested sub-pipelines (inside `$lookup.pipeline`,
  # `$unionWith.pipeline`, `$facet.*`, `$graphLookup`) are walked with
  # the operator denylist but NOT with the stage allowlist. This is
  # intentional: Atlas Search and uncommon-but-legitimate read stages
  # like `$densify` and `$fill` must be allowed inside sub-pipelines
  # even when the outer pipeline is strict-validated. The denylist is
  # the security boundary; the allowlist is a shape check.
  #
  # == Caveat for {Parse::Query#aggregate} callers
  #
  # `Parse::Query#aggregate` routes through {validate_filter!}, not
  # {validate_pipeline!}, so user-supplied pipelines are checked
  # against the denylist only. Permissive mode does NOT block
  # `$lookup`, `$graphLookup`, or `$unionWith` reading from arbitrary
  # collections — these are legitimate read stages but powerful enough
  # to cross Parse ACL/CLP boundaries when the source collection lacks
  # row-level enforcement. **Never pass raw attacker-controlled input
  # into `Parse::Query#aggregate`.** Construct the pipeline in SDK code
  # and interpolate only validated values.
  #
  # == Capability gap: `$expr`
  #
  # `$expr` itself is not in {DENIED_OPERATORS}. The recursive walker
  # catches `$function`/`$accumulator` nested inside `$expr`, so the
  # immediate JavaScript-execution risk is closed. A future Atlas
  # operator gated under `$expr` would slip until {DENIED_OPERATORS}
  # is extended. Defense-in-depth callers concerned about expensive
  # aggregation expressions (`$regexMatch` ReDoS, large `$reduce`
  # loops) should validate user input shape before reaching this
  # module.
  module PipelineSecurity
    # Raised when a pipeline or filter contains a forbidden stage or
    # operator. Inherits from `Parse::Error` so callers can rescue both
    # this and other Parse SDK errors with one rescue clause.
    class Error < Parse::Error
      attr_reader :stage, :operator, :reason

      def initialize(message, stage: nil, operator: nil, reason: nil)
        @stage = stage
        @operator = operator
        @reason = reason
        super(message)
      end
    end

    # Operators that are ALWAYS refused at any nesting depth. These either
    # execute server-side JavaScript (`$where`, `$function`,
    # `$accumulator`) or mutate the database (`$out`, `$merge`) or the
    # server itself (`$collMod`, `$createIndex`, `$dropIndex`,
    # `$planCacheSetFilter`, `$planCacheClear`). None of them are needed
    # for read queries.
    DENIED_OPERATORS = %w[
      $where $function $accumulator
      $out $merge
      $collMod $createIndex $dropIndex
      $planCacheSetFilter $planCacheClear
    ].freeze

    # Top-level pipeline stages permitted by the strict validator. The
    # set covers Parse-Stack's own aggregation use, plus Atlas Search
    # entry points (`$search`, `$searchMeta`, `$listSearchIndexes`) so
    # that `Parse::AtlasSearch` calls do not break.
    ALLOWED_STAGES = %w[
      $match $group $sort $project $limit $skip $unwind $lookup
      $count $addFields $set $unset $bucket $bucketAuto $facet
      $sample $sortByCount $replaceRoot $replaceWith $redact
      $graphLookup $unionWith
      $search $searchMeta $listSearchIndexes
    ].freeze

    # Cap on number of top-level stages in a strict-validated pipeline.
    MAX_PIPELINE_STAGES = 20

    # Cap on nested object/array depth during recursive walks. Stops a
    # caller from forcing the validator into a near-infinite traversal.
    # Legitimate Parse-generated pipelines with `$facet` containing
    # `$lookup` with `let` and correlated sub-pipelines (`$match.$expr.
    # $and.[…]`) can reach depth 12+ on a normal read, so we keep
    # comfortable headroom above the real ceiling.
    MAX_DEPTH = 20

    module_function

    # Strict validation: pipeline must be a non-empty Array of Hashes,
    # each Hash's top-level key must be in {ALLOWED_STAGES}, and no
    # entry in {DENIED_OPERATORS} may appear at any nesting depth.
    #
    # @param pipeline [Array<Hash>] the aggregation pipeline.
    # @raise [Error] if validation fails.
    # @return [true]
    def validate_pipeline!(pipeline)
      unless pipeline.is_a?(Array)
        raise Error.new("Pipeline must be an Array, got #{pipeline.class}", reason: :invalid_type)
      end
      if pipeline.empty?
        raise Error.new("Pipeline cannot be empty", reason: :empty_pipeline)
      end
      if pipeline.size > MAX_PIPELINE_STAGES
        raise Error.new(
          "Pipeline exceeds maximum of #{MAX_PIPELINE_STAGES} stages (got #{pipeline.size})",
          reason: :too_many_stages,
        )
      end

      pipeline.each_with_index do |stage, idx|
        validate_stage!(stage, idx)
      end
      true
    end

    # Permissive validation: walks the given Hash or Array (or anything
    # else, which is a no-op) and refuses any nested key that appears
    # in {DENIED_OPERATORS}. Does NOT check the top-level stage
    # allowlist or the stage count cap. Used by direct-MongoDB sinks
    # where callers have explicit intent and want flexibility in stage
    # selection, but server-side JS and data-mutating operators must
    # still be refused.
    #
    # @param node [Hash, Array, Object] the structure to walk.
    # @raise [Error] if a denied operator is found at any depth.
    # @return [true]
    def validate_filter!(node)
      walk_for_denied!(node, depth: 0)
      true
    end

    # @return [Boolean] true if the pipeline passes strict validation.
    def valid_pipeline?(pipeline)
      validate_pipeline!(pipeline)
      true
    rescue Error
      false
    end

    # @return [Boolean] true if the node passes permissive validation.
    def valid_filter?(node)
      validate_filter!(node)
      true
    rescue Error
      false
    end

    # @!visibility private
    def validate_stage!(stage, idx)
      unless stage.is_a?(Hash)
        raise Error.new(
          "Pipeline stage #{idx} must be a Hash, got #{stage.class}",
          stage: idx,
          reason: :invalid_stage_type,
        )
      end

      stage.each do |key, value|
        key_str = key.to_s

        if DENIED_OPERATORS.include?(key_str)
          raise Error.new(
            "SECURITY: Pipeline stage #{idx} uses denied operator '#{key_str}'. " \
            "This operator either executes server-side JavaScript or mutates data, " \
            "and is refused at any nesting depth.",
            stage: idx,
            operator: key_str,
            reason: :denied_operator,
          )
        end

        if key_str.start_with?("$") && !ALLOWED_STAGES.include?(key_str)
          raise Error.new(
            "SECURITY: Unknown aggregation stage '#{key_str}' at index #{idx} is not in the " \
            "allowed stage list. Allowed: #{ALLOWED_STAGES.join(", ")}.",
            stage: idx,
            operator: key_str,
            reason: :unknown_stage,
          )
        end

        walk_for_denied!(value, depth: 1, stage_idx: idx)
      end
    end
    private_class_method :validate_stage!

    # @!visibility private
    def walk_for_denied!(node, depth:, stage_idx: nil)
      if depth > MAX_DEPTH
        raise Error.new(
          "Pipeline nesting depth exceeded (#{MAX_DEPTH}). " \
          "Refusing to walk pathologically nested structures.",
          stage: stage_idx,
          reason: :max_depth_exceeded,
        )
      end

      case node
      when Hash
        node.each do |key, value|
          key_str = key.to_s
          if DENIED_OPERATORS.include?(key_str)
            raise Error.new(
              "SECURITY: Nested denied operator '#{key_str}' found at nesting depth #{depth}" \
              "#{stage_idx ? " inside stage #{stage_idx}" : ""}. " \
              "This operator either executes server-side JavaScript or mutates data, " \
              "and is refused at any depth.",
              stage: stage_idx,
              operator: key_str,
              reason: :nested_denied_operator,
            )
          end
          walk_for_denied!(value, depth: depth + 1, stage_idx: stage_idx)
        end
      when Array
        node.each { |item| walk_for_denied!(item, depth: depth + 1, stage_idx: stage_idx) }
      end
      # Primitives (String, Integer, etc.) are always safe.
      nil
    end
    private_class_method :walk_for_denied!
  end
end
