# encoding: UTF-8
# frozen_string_literal: true

require "timeout"

module Parse
  class Agent
    # The Tools module contains all the executable tool implementations
    # for the Parse Agent. Each tool is a class method that takes an agent
    # instance and keyword arguments.
    #
    # Tools are divided into categories:
    # - **Schema tools**: get_all_schemas, get_schema
    # - **Query tools**: query_class, count_objects, get_object, get_sample_objects, get_objects
    # - **Analysis tools**: aggregate, explain_query
    #
    # == Custom Tool Registration
    #
    # Third-party apps may register additional tools:
    #
    #   Parse::Agent::Tools.register(
    #     name:        :breakdown_captures,
    #     description: "Count captures grouped by user/...",
    #     parameters:  { type: "object", properties: {...}, required: [...] },
    #     permission:  :readonly,
    #     timeout:     30,
    #     handler:     ->(agent, **args) { { result: "..." } }
    #   )
    #
    # Registering a name that matches an existing registration replaces it
    # (idempotent on name). Call reset_registry! to clear all registrations
    # (useful in test suites).
    #
    module Tools
      extend self

      # Methods that are dangerous and should never be invoked via tools.
      # Defined here (rather than MCPServer) so it's always available.
      BLOCKED_METHODS = %w[
        eval exec system ` send __send__ public_send
        instance_eval class_eval module_eval
        instance_exec class_exec module_exec
        define_method define_singleton_method remove_method undef_method
        singleton_class
        open fork spawn syscall load require require_relative
        const_get const_set remove_const method binding
        instance_variable_set instance_variable_get
      ].freeze

      # Default timeout for tool operations (seconds)
      DEFAULT_TIMEOUT = 30

      # Per-tool timeout overrides for long-running operations.
      # Frozen — do not mutate. Use Tools.timeout_for(name) to resolve
      # timeouts that overlay registered-tool values on top of this table.
      TOOL_TIMEOUTS = {
        aggregate: 60,
        query_class: 30,
        explain_query: 30,
        call_method: 60,
        get_all_schemas: 15,
        get_schema: 10,
        count_objects: 20,
        get_object: 10,
        get_objects: 20,
        get_sample_objects: 15,
      }.freeze

      # Derive a MongoDB maxTimeMS budget for a given tool name.
      # Subtracts a 5-second buffer from the tool's Ruby-level timeout so the
      # database cancels the query before the outer {with_timeout} fires,
      # turning the unsafe {Timeout.timeout} into an unreachable fallback.
      #
      # @param tool_name [Symbol] the tool name key (matches {TOOL_TIMEOUTS})
      # @return [Integer] budget in milliseconds (never below 5_000)
      #
      # @example
      #   Tools.max_time_ms_for(:aggregate)    # => 55_000 (60s - 5s)
      #   Tools.max_time_ms_for(:query_class)  # => 25_000 (30s - 5s)
      #   Tools.max_time_ms_for(:nonexistent)  # => 25_000 (DEFAULT_TIMEOUT 30s - 5s)
      def max_time_ms_for(tool_name)
        secs = TOOL_TIMEOUTS[tool_name] || DEFAULT_TIMEOUT
        budget = [secs - 5, 5].max
        budget * 1000
      end

      # Tool definitions in OpenAI function calling format
      # Optimized for token efficiency - LLMs understand from context
      TOOL_DEFINITIONS = {
        get_all_schemas: {
          name: "get_all_schemas",
          description: "List all classes with field counts",
          parameters: { type: "object", properties: {}, required: [] },
        },

        get_schema: {
          name: "get_schema",
          description: "Get class fields and types",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
            },
            required: ["class_name"],
          },
        },

        query_class: {
          name: "query_class",
          description: "Query objects with constraints",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
              limit: { type: "integer" },
              skip: { type: "integer" },
              order: { type: "string" },
              keys: { type: "array", items: { type: "string" } },
              include: { type: "array", items: { type: "string" } },
            },
            required: ["class_name"],
          },
        },

        count_objects: {
          name: "count_objects",
          description: "Count matching objects",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
            },
            required: ["class_name"],
          },
        },

        get_object: {
          name: "get_object",
          description: "Fetch by objectId",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              object_id: { type: "string" },
              include: { type: "array", items: { type: "string" } },
            },
            required: ["class_name", "object_id"],
          },
        },

        get_objects: {
          name: "get_objects",
          description: "Batch-fetch multiple Parse objects by id in a single query. Use this instead of multiple get_object calls when dereferencing pointers.",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string", description: "Parse class name" },
              ids: { type: "array", items: { type: "string" }, description: "Array of objectId values (max 50, dedup'd)" },
              include: { type: "array", items: { type: "string" }, description: "Pointer fields to include/resolve" },
            },
            required: ["class_name", "ids"],
          },
        },

        get_sample_objects: {
          name: "get_sample_objects",
          description: "Sample objects from class",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              limit: { type: "integer" },
            },
            required: ["class_name"],
          },
        },

        aggregate: {
          name: "aggregate",
          description: "MongoDB aggregation pipeline",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              pipeline: { type: "array", items: { type: "object" } },
            },
            required: ["class_name", "pipeline"],
          },
        },

        explain_query: {
          name: "explain_query",
          description: "Query execution plan",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              where: { type: "object" },
            },
            required: ["class_name"],
          },
        },

        call_method: {
          name: "call_method",
          description: "Call agent-allowed method",
          parameters: {
            type: "object",
            properties: {
              class_name: { type: "string" },
              method_name: { type: "string" },
              object_id: { type: "string" },
              arguments: { type: "object" },
            },
            required: ["class_name", "method_name"],
          },
        },
      }.freeze

      # ============================================================
      # CUSTOM TOOL REGISTRY (Feature 1)
      # ============================================================

      # Thread-safety for the mutable registry. Private constant to
      # avoid leaking mutex into public API surface.
      REGISTRY_MUTEX = Mutex.new
      private_constant :REGISTRY_MUTEX

      # Mutable registry of custom tools: Symbol name => registration Hash
      # Each entry: { definition:, permission:, timeout:, handler: }
      @registry = {}

      class << self
        # Register a custom tool. Thread-safe. Idempotent on name (replaces).
        #
        # @param name [Symbol] unique tool name (required)
        # @param description [String] human-readable description (required)
        # @param parameters [Hash] JSON Schema object definition (required)
        # @param permission [Symbol] :readonly, :write, or :admin (required)
        # @param timeout [Integer] seconds before ToolTimeoutError (default: 30)
        # @param handler [Proc] lambda(agent, **args) -> Hash (required)
        # @raise [ArgumentError] when required kwargs are missing or permission is invalid
        def register(name:, description:, parameters:, permission:, handler:, timeout: DEFAULT_TIMEOUT)
          unless %i[readonly write admin].include?(permission)
            raise ArgumentError, "permission must be :readonly, :write, or :admin (got #{permission.inspect})"
          end
          raise ArgumentError, "handler must be a callable (Proc/lambda)" unless handler.respond_to?(:call)
          raise ArgumentError, "name is required" if name.nil?
          raise ArgumentError, "description is required" if description.nil? || description.to_s.empty?
          raise ArgumentError, "parameters is required" if parameters.nil?

          sym = name.to_sym
          definition = {
            name: sym.to_s,
            description: description.to_s,
            parameters: parameters,
          }

          REGISTRY_MUTEX.synchronize do
            @registry[sym] = {
              definition: definition,
              permission: permission,
              timeout: timeout.to_i,
              handler: handler,
            }
          end
          nil
        end

        # Clear all custom registrations, restoring builtins-only state.
        # Intended for test suites.
        def reset_registry!
          REGISTRY_MUTEX.synchronize { @registry.clear }
          nil
        end

        # Dispatch a tool call. Registered tools take precedence over builtins
        # only when both share a name; otherwise each path is exclusive.
        #
        # @param agent [Parse::Agent] the agent instance
        # @param name [Symbol, String] tool name
        # @param kwargs [Hash] keyword arguments forwarded to handler or builtin
        def invoke(agent, name, **kwargs)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }

          if entry
            entry[:handler].call(agent, **kwargs)
          else
            Tools.send(sym, agent, **kwargs)
          end
        end

        # Resolve the permission level for a tool (builtin or registered).
        #
        # @param name [Symbol, String] tool name
        # @return [Symbol] :readonly, :write, :admin, or :unknown
        def permission_for(name)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          return entry[:permission] if entry

          Parse::Agent::PERMISSION_LEVELS.each do |level, tools|
            return level if tools.include?(sym)
          end
          :unknown
        end

        # Resolve the timeout for a tool (registered overlay wins over builtin table).
        #
        # @param name [Symbol, String] tool name
        # @return [Integer] seconds
        def timeout_for(name)
          sym = name.to_sym
          entry = REGISTRY_MUTEX.synchronize { @registry[sym] }
          return entry[:timeout] if entry
          TOOL_TIMEOUTS[sym] || DEFAULT_TIMEOUT
        end

        # Returns all tool names: builtins + registered.
        #
        # @return [Array<Symbol>]
        def all_tool_names
          builtin = TOOL_DEFINITIONS.keys
          registered = REGISTRY_MUTEX.synchronize { @registry.keys }
          (builtin + registered).uniq
        end

        # Returns registered tool names that are accessible at the given permission level.
        #
        # @param permission [Symbol] :readonly, :write, or :admin
        # @return [Array<Symbol>]
        def registered_tools_for(permission)
          hierarchy = { readonly: 0, write: 1, admin: 2 }
          agent_level = hierarchy[permission] || 0
          REGISTRY_MUTEX.synchronize do
            @registry.select { |_name, entry|
              required = hierarchy[entry[:permission]] || 0
              agent_level >= required
            }.keys
          end
        end
      end

      # Get tool definitions for allowed tools, merging registered definitions.
      #
      # @param allowed_tools [Array<Symbol>] list of tool names to include
      # @param format [Symbol] output format (:openai or :mcp)
      # @return [Array<Hash>] tool definitions
      def definitions(allowed_tools, format: :openai)
        # Build a merged definition map: builtins first, registered on top
        registered_defs = REGISTRY_MUTEX.synchronize do
          @registry.transform_values { |entry| entry[:definition] }
        end

        defs = allowed_tools.filter_map do |tool_name|
          sym = tool_name.to_sym
          registered_defs[sym] || TOOL_DEFINITIONS[sym]
        end

        case format
        when :mcp
          defs.map { |d| to_mcp_format(d) }
        else
          defs.map { |d| { type: "function", function: d } }
        end
      end

      # Convert OpenAI format to MCP format
      def to_mcp_format(definition)
        {
          name: definition[:name],
          description: definition[:description],
          inputSchema: definition[:parameters],
        }
      end

      # ============================================================
      # SCHEMA TOOLS
      # ============================================================

      # Get all schemas from the Parse server
      #
      # @param agent [Parse::Agent] the agent instance
      # @return [Hash] formatted schema information
      def get_all_schemas(agent, **_kwargs)
        response = agent.client.schemas(agent.request_opts)

        unless response.success?
          raise "Failed to fetch schemas: #{response.error}"
        end

        # response.result is already the results array (Parse::Response extracts it)
        schemas = response.results

        # Enrich with local model metadata (descriptions, agent methods)
        enriched = MetadataRegistry.enriched_schemas(schemas, agent_permission: agent.permissions)

        ResultFormatter.format_schemas(enriched)
      end

      # Get schema for a specific class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @return [Hash] formatted schema information
      def get_schema(agent, class_name:, **_kwargs)
        response = agent.client.schema(class_name)

        unless response.success?
          raise "Failed to fetch schema for '#{class_name}': #{response.error}"
        end

        # Enrich with local model metadata (descriptions, agent methods)
        enriched = MetadataRegistry.enriched_schema(class_name, response.result, agent_permission: agent.permissions)

        ResultFormatter.format_schema(enriched)
      end

      # ============================================================
      # QUERY TOOLS
      # ============================================================

      # Query objects from a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @param limit [Integer] max results (default 100)
      # @param skip [Integer] pagination offset
      # @param order [String] sort field (prefix with '-' for desc)
      # @param keys [Array<String>] fields to select
      # @param include [Array<String>] pointer fields to include
      # @return [Hash] query results, or a refusal hash if COLLSCAN detected
      # @raise [ConstraintTranslator::ConstraintSecurityError] if blocked operators are used
      def query_class(agent, class_name:, where: nil, limit: nil, skip: nil,
                             order: nil, keys: nil, include: nil, **_kwargs)
        limit = [limit || Agent::DEFAULT_LIMIT, Agent::MAX_LIMIT].min

        # COLLSCAN pre-flight check (Feature 3):
        # Only runs when refuse_collscan is enabled globally AND the class has
        # not opted out via agent_allow_collscan, AND where is non-empty.
        if where && !where.empty? &&
           Parse::Agent.refuse_collscan? &&
           !MetadataRegistry.allow_collscan?(class_name)

          refusal = collscan_preflight(agent, class_name, where)
          return refusal if refusal
        end

        # Build query hash
        query = {}
        query[:limit] = limit
        query[:skip] = skip if skip && skip > 0
        query[:order] = order if order
        # Apply caller-supplied keys verbatim; if absent, fall back to the model's
        # agent_fields allowlist so the LLM only sees analytics-relevant columns.
        effective_keys = keys&.any? ? keys.map(&:to_s) : MetadataRegistry.field_allowlist(class_name)
        query[:keys] = effective_keys.join(",") if effective_keys&.any?
        query[:include] = include.join(",") if include&.any?

        # SECURITY: Constraint validation happens in ConstraintTranslator.translate
        # This blocks dangerous operators like $where, $function
        if where && !where.empty?
          query[:where] = ConstraintTranslator.translate(where).to_json
        end

        with_timeout(:query_class) do
          response = agent.client.find_objects(class_name, query, **agent.request_opts)

          unless response.success?
            raise "Query failed: #{response.error}"
          end

          # response.results returns the array (Parse::Response extracts it)
          results = response.results
          ResultFormatter.format_query_results(class_name, results, limit: limit, skip: skip || 0)
        end
      end

      # Count objects in a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @return [Hash] count result
      def count_objects(agent, class_name:, where: nil, **_kwargs)
        query = { limit: 0, count: 1 }

        if where && !where.empty?
          query[:where] = ConstraintTranslator.translate(where).to_json
        end

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          raise "Count failed: #{response.error}"
        end

        {
          class_name: class_name,
          count: response.count,
          constraints: where || {},
        }
      end

      # Get a single object by ID
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param object_id [String] the objectId
      # @param include [Array<String>] pointer fields to include
      # @return [Hash] the object data
      # @raise [Parse::Agent::ValidationError] for invalid class_name or object_id
      def get_object(agent, class_name:, object_id:, include: nil, **_kwargs)
        query = {}
        query[:include] = include.join(",") if include&.any?

        # Project to the agent_fields allowlist when one is declared
        allowlist = MetadataRegistry.field_allowlist(class_name)
        query[:keys] = allowlist.join(",") if allowlist&.any?

        response = agent.client.fetch_object(class_name, object_id, query: query, **agent.request_opts)

        unless response.success?
          if response.object_not_found?
            raise "Object not found: #{class_name}##{object_id}"
          end
          raise "Fetch failed: #{response.error}"
        end

        ResultFormatter.format_object(class_name, response.result)
      end

      # Batch-fetch multiple Parse objects by id in a single query.
      # Prefer this over multiple get_object calls when dereferencing pointers.
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param ids [Array<String>] objectId values to fetch (max 50, dedup'd)
      # @param include [Array<String>] pointer fields to include/resolve
      # @return [Hash] { class_name:, objects:, missing:, requested:, found: }
      # @raise [Parse::Agent::ValidationError] if class_name invalid, ids not an Array,
      #   any id has invalid format, or more than 50 unique ids are requested
      def get_objects(agent, class_name:, ids: nil, include: [], **_kwargs)
        # Validate class_name
        unless class_name.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/)
          raise Parse::Agent::ValidationError,
                "class_name must match identifier pattern (got: #{class_name.inspect})"
        end

        # nil ids is an error (required parameter); empty array is a valid empty result
        if ids.nil?
          raise Parse::Agent::ValidationError, "ids is required"
        end

        unless ids.is_a?(Array)
          raise Parse::Agent::ValidationError, "ids must be an Array of Strings"
        end

        # Short-circuit on empty array — no query needed
        if ids.empty?
          return {
            class_name: class_name,
            objects: {},
            missing: [],
            requested: 0,
            found: 0,
          }
        end

        unique_ids = ids.uniq

        if unique_ids.size > 50
          raise Parse::Agent::ValidationError,
                "ids exceeds the 50-object limit (#{unique_ids.size} unique ids). " \
                "For larger sets use query_class with an $in constraint."
        end

        # Validate each id format
        unique_ids.each do |id|
          unless id.is_a?(String) && id.match?(/\A[A-Za-z0-9]{1,32}\z/)
            raise Parse::Agent::ValidationError,
                  "each id must match /\\A[A-Za-z0-9]{1,32}\\z/ (got: #{id.inspect})"
          end
        end

        # Build query
        query = {
          where: { "objectId" => { "$in" => unique_ids } }.to_json,
          limit: unique_ids.size,
        }
        query[:include] = include.join(",") if include&.any?

        # Apply agent_fields allowlist as keys projection
        allowlist = MetadataRegistry.field_allowlist(class_name)
        query[:keys] = allowlist.join(",") if allowlist&.any?

        with_timeout(:get_objects) do
          response = agent.client.find_objects(class_name, query, **agent.request_opts)

          unless response.success?
            raise "Batch fetch failed: #{response.error}"
          end

          results = response.results
          objects_by_id = results.each_with_object({}) do |obj, h|
            oid = obj.is_a?(Hash) ? (obj["objectId"] || obj[:objectId]) : obj.id
            h[oid] = obj
          end

          missing = unique_ids.reject { |id| objects_by_id.key?(id) }

          {
            class_name: class_name,
            objects: objects_by_id,
            missing: missing,
            requested: unique_ids.size,
            found: objects_by_id.size,
          }
        end
      end

      # Get sample objects from a class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param limit [Integer] number of samples (default 5, max 20)
      # @return [Hash] sample objects
      def get_sample_objects(agent, class_name:, limit: nil, **_kwargs)
        limit = [limit || 5, 20].min

        query = {
          limit: limit,
          order: "-createdAt",
        }

        # Project to the agent_fields allowlist when one is declared
        allowlist = MetadataRegistry.field_allowlist(class_name)
        query[:keys] = allowlist.join(",") if allowlist&.any?

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          raise "Sample query failed: #{response.error}"
        end

        # response.results returns the array (Parse::Response extracts it)
        results = response.results
        {
          class_name: class_name,
          sample_count: results.size,
          samples: results.map { |obj| ResultFormatter.format_object(class_name, obj)[:object] },
          note: "These are the #{results.size} most recently created objects",
        }
      end

      # ============================================================
      # ANALYSIS TOOLS
      # ============================================================

      # Run an aggregation pipeline
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param pipeline [Array<Hash>] MongoDB aggregation pipeline
      # @return [Hash] aggregation results, or a refusal hash if COLLSCAN detected
      # @raise [PipelineValidator::PipelineSecurityError] if pipeline contains blocked stages
      def aggregate(agent, class_name:, pipeline:, **_kwargs)
        # SECURITY: Validate pipeline BEFORE execution
        # This blocks dangerous stages like $out, $merge, $function
        PipelineValidator.validate!(pipeline)

        # COLLSCAN pre-flight check (Feature 3):
        # Extract a leading $match stage as the implicit "where" for aggregations.
        # If the pipeline doesn't begin with $match, skip pre-flight — the caller
        # is doing a deliberate scan-then-reduce and refusing would be hostile.
        if Parse::Agent.refuse_collscan? &&
           !MetadataRegistry.allow_collscan?(class_name) &&
           (match_stage = pipeline.first&.dig("$match"))&.any?

          refusal = collscan_preflight(agent, class_name, match_stage)
          return refusal if refusal
        end

        with_timeout(:aggregate) do
          response = agent.client.aggregate_pipeline(class_name, pipeline, **agent.request_opts)

          unless response.success?
            raise "Aggregation failed: #{response.error}"
          end

          # response.results returns the array (Parse::Response extracts it)
          results = response.results
          {
            class_name: class_name,
            pipeline_stages: pipeline.size,
            result_count: results.size,
            results: results,
          }
        end
      end

      # Explain a query's execution plan
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param where [Hash] query constraints
      # @return [Hash] query explanation
      def explain_query(agent, class_name:, where: nil, **_kwargs)
        query = { explain: true, limit: 1 }

        if where && !where.empty?
          query[:where] = ConstraintTranslator.translate(where).to_json
        end

        response = agent.client.find_objects(class_name, query, **agent.request_opts)

        unless response.success?
          raise "Explain failed: #{response.error}"
        end

        {
          class_name: class_name,
          constraints: where || {},
          explanation: response.result,
        }
      end

      # ============================================================
      # METHOD TOOLS
      # ============================================================

      # Call an agent-allowed method on a Parse class
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] the Parse class name
      # @param method_name [String] the name of the method to call
      # @param object_id [String, nil] object ID for instance methods
      # @param arguments [Hash] method arguments
      # @return [Hash] method result
      def call_method(agent, class_name:, method_name:, object_id: nil, arguments: nil, **_kwargs)
        klass = Parse::Model.find_class(class_name)
        raise "Class not found: #{class_name}" unless klass

        method_sym = method_name.to_sym

        # Check if method is agent-allowed
        unless klass.respond_to?(:agent_method_allowed?) && klass.agent_method_allowed?(method_sym)
          raise "Method '#{method_name}' is not agent-allowed on #{class_name}. " \
                "Only methods marked with agent_method, agent_readonly, agent_write, or agent_admin can be called."
        end

        # Check permission level
        unless klass.agent_can_call?(method_sym, agent.permissions)
          method_info = klass.agent_method_info(method_sym)
          required = method_info[:permission] || :readonly
          raise "Permission denied: '#{method_name}' requires #{required} permissions. " \
                "Current level: #{agent.permissions}"
        end

        method_info = klass.agent_method_info(method_sym)
        args = arguments || {}
        args = args.transform_keys(&:to_sym) if args.is_a?(Hash)

        # Execute with timeout - user methods could be slow
        with_timeout(:call_method) do
          result = if method_info[:type] == :instance
              raise "object_id required for instance method '#{method_name}'" unless object_id
              obj = klass.find(object_id)
              raise "Object not found: #{class_name}##{object_id}" unless obj
              call_with_args(obj, method_sym, args)
            else
              call_with_args(klass, method_sym, args)
            end

          {
            class_name: class_name,
            method: method_name,
            object_id: object_id,
            result: serialize_result(result),
          }
        end
      end

      private

      # Execute a block with a timeout.
      # Resolves timeout via Tools.timeout_for so registered-tool overrides are honoured.
      # @param tool_name [Symbol] the tool being executed (for error messages)
      # @yield the block to execute with timeout
      # @raise [Agent::ToolTimeoutError] if timeout is exceeded
      def with_timeout(tool_name)
        timeout = Tools.timeout_for(tool_name)
        Timeout.timeout(timeout) { yield }
      rescue Timeout::Error
        raise Agent::ToolTimeoutError.new(tool_name, timeout)
      end

      # ============================================================
      # COLLSCAN pre-flight helpers (Feature 3)
      # ============================================================

      # Run a cheap explain pre-flight on the given where clause.
      # Returns a refusal hash if COLLSCAN is detected, nil if safe to proceed.
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] Parse class name
      # @param where [Hash] raw (untranslated) where constraints
      # @return [Hash, nil] refusal hash or nil
      def collscan_preflight(agent, class_name, where)
        explain_result = run_explain(agent, class_name, where)
        return nil unless explain_result

        winning_plan = explain_result.dig("queryPlanner", "winningPlan") ||
                       explain_result["winningPlan"] ||
                       explain_result

        if collscan?(winning_plan)
          plan_summary = summarize_plan(winning_plan)
          {
            refused: true,
            reason: "COLLSCAN on #{class_name}",
            suggestion: "Add a filter on an indexed field, or call explain_query directly to inspect the plan.",
            winning_plan: plan_summary,
          }
        else
          nil
        end
      end

      # Detect COLLSCAN in a query plan node. Recursively walks inputStage/inputStages.
      #
      # @param plan [Hash, nil] winning plan node
      # @return [Boolean]
      def collscan?(plan)
        return false unless plan.is_a?(Hash)
        return true if plan["stage"] == "COLLSCAN"

        # Recurse into nested inputStage
        return true if collscan?(plan["inputStage"])

        # Recurse into parallel inputStages array (OR_STAGE, etc.)
        if plan["inputStages"].is_a?(Array)
          return true if plan["inputStages"].any? { |s| collscan?(s) }
        end

        false
      end

      # Run an explain query on the given where hash, returning the parsed result hash.
      # Translates constraints for security. Returns nil on any failure (fail open).
      #
      # @param agent [Parse::Agent] the agent instance
      # @param class_name [String] Parse class name
      # @param where [Hash] raw where constraints
      # @return [Hash, nil]
      def run_explain(agent, class_name, where)
        query = { explain: true, limit: 1 }
        query[:where] = ConstraintTranslator.translate(where).to_json
        response = agent.client.find_objects(class_name, query, **agent.request_opts)
        return nil unless response.success?
        response.result
      rescue StandardError
        nil
      end

      # Produce a compact, human-readable summary of a plan node.
      #
      # @param plan [Hash, nil]
      # @return [String]
      def summarize_plan(plan)
        return "unknown" unless plan.is_a?(Hash)
        stage = plan["stage"] || "unknown"
        filter = plan["filter"] ? " filter=#{plan["filter"].inspect}" : ""
        "#{stage}#{filter}"
      end

      # Call a method with arguments using parameter introspection.
      #
      # We avoid the prior "try kwargs, rescue ArgumentError, retry with no args"
      # pattern because it silently swallows real ArgumentErrors raised from inside
      # the method body (e.g. validation failures), making bugs invisible. Instead
      # we look at Method#parameters and either pass kwargs, or raise a clear
      # error explaining why the call can't be made.
      #
      # @raise [ArgumentError] if the method is blocked, takes positional args
      #   only, or accepts no args but was called with some.
      def call_with_args(target, method_sym, args)
        validate_method_name!(method_sym)
        return target.public_send(method_sym) if args.nil? || args.empty?

        param_types = target.method(method_sym).parameters.map(&:first)
        accepts_kwargs = (param_types & %i[key keyreq keyrest]).any?

        if accepts_kwargs
          target.public_send(method_sym, **args)
        elsif (param_types & %i[req opt rest]).any?
          raise ArgumentError,
                "Method '#{method_sym}' takes positional arguments only; " \
                "agent-exposed methods must accept keyword arguments " \
                "(received #{truncated_keys(args)})."
        else
          raise ArgumentError,
                "Method '#{method_sym}' takes no arguments but was called " \
                "with #{truncated_keys(args)}."
        end
      end

      # Compact, bounded preview of arg keys for use in error messages.
      # Caps at 5 keys so a caller cannot use long error messages as an
      # enumeration oracle for which kwargs round-trip through the agent.
      def truncated_keys(args)
        keys = args.keys
        shown = keys.first(5).join(", ")
        keys.size > 5 ? "#{keys.size} keys (#{shown}, ...)" : "keys: #{shown}"
      end

      # Validates that a method name is not on the blocked list.
      # Comparison is case-insensitive so e.g. `:Instance_Exec` cannot bypass the
      # denylist on Ruby versions / receivers where casing variations are valid.
      # @param method_name [Symbol, String] the method name to validate.
      # @raise [ArgumentError] if the method is blocked.
      def validate_method_name!(method_name)
        if BLOCKED_METHODS.include?(method_name.to_s.downcase)
          raise ArgumentError, "Method '#{method_name}' is blocked for security reasons"
        end
      end

      # Serialize method results for JSON output
      def serialize_result(result)
        case result
        when Parse::Object
          ResultFormatter.format_object(result.parse_class, result.attributes)[:object]
        when Array
          result.map { |item| serialize_result(item) }
        when Hash
          result.transform_values { |v| serialize_result(v) }
        when NilClass, TrueClass, FalseClass, Numeric, String
          result
        else
          result.to_s
        end
      end
    end
  end
end
