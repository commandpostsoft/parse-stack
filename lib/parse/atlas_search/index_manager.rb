# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module AtlasSearch
    # Manages Atlas Search index discovery and caching.
    # Uses $listSearchIndexes aggregation stage to discover available indexes.
    #
    # The cache is process-local, time-bounded (default 300 seconds), and
    # protected by a Mutex. Override the TTL via:
    #
    #   Parse::AtlasSearch::IndexManager.cache_ttl = 60  # seconds
    #
    # @example List indexes
    #   indexes = Parse::AtlasSearch::IndexManager.list_indexes("Song")
    #   # => [{"name" => "default", "status" => "READY", ...}]
    #
    # @example Check if index is ready
    #   IndexManager.index_ready?("Song", "song_search")
    #   # => true
    module IndexManager
      # Default cache TTL in seconds. Index definitions rarely change at
      # runtime, but new indexes built via the Atlas UI should become
      # visible without a process restart.
      DEFAULT_CACHE_TTL = 300

      class << self
        # @return [Numeric] the cache TTL in seconds. Set to 0 or negative
        #   to disable caching entirely.
        attr_writer :cache_ttl

        def cache_ttl
          @cache_ttl || DEFAULT_CACHE_TTL
        end

        # List all search indexes for a collection (cached).
        # Uses the $listSearchIndexes aggregation stage.
        #
        # @param collection_name [String] the Parse collection name
        # @param force_refresh [Boolean] bypass cache and fetch fresh data
        # @return [Array<Hash>] array of index definitions with keys:
        #   - id: String - the index ID
        #   - name: String - the index name
        #   - status: String - "READY", "BUILDING", etc.
        #   - queryable: Boolean - whether the index is queryable
        #   - mappings: Hash - field mappings definition
        def list_indexes(collection_name, force_refresh: false)
          if !force_refresh
            cached = cache_mutex.synchronize do
              cached_indexes(collection_name) if cache_valid?(collection_name)
            end
            return cached if cached
          end

          # $listSearchIndexes must be the first and only stage in pipeline
          pipeline = [{ "$listSearchIndexes" => {} }]

          begin
            results = Parse::MongoDB.aggregate(collection_name, pipeline)
            cache_mutex.synchronize { cache_indexes(collection_name, results) }
            results
          rescue => e
            handle_list_error(e, collection_name)
          end
        end

        # Check if a search index exists for a collection
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to check
        # @return [Boolean] true if index exists
        def index_exists?(collection_name, index_name)
          indexes = list_indexes(collection_name)
          indexes.any? { |idx| idx["name"] == index_name }
        end

        # Check if a search index exists and is ready to query
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to check
        # @return [Boolean] true if index exists and is queryable
        def index_ready?(collection_name, index_name)
          indexes = list_indexes(collection_name)
          index = indexes.find { |idx| idx["name"] == index_name }
          index.present? && index["queryable"] == true
        end

        # Get a specific index definition
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name
        # @return [Hash, nil] the index definition or nil if not found
        def get_index(collection_name, index_name)
          indexes = list_indexes(collection_name)
          indexes.find { |idx| idx["name"] == index_name }
        end

        # Validate that an index exists and is ready
        # @param collection_name [String] the Parse collection name
        # @param index_name [String] the index name to validate
        # @raise [IndexNotFound] if the index doesn't exist or isn't ready
        def validate_index!(collection_name, index_name)
          unless index_ready?(collection_name, index_name)
            available = list_indexes(collection_name).map { |i| i["name"] }.join(", ")
            raise IndexNotFound,
              "Atlas Search index '#{index_name}' not found or not ready on collection '#{collection_name}'. " \
              "Available indexes: #{available.presence || "none"}"
          end
        end

        # Clear the index cache
        # @param collection_name [String, nil] specific collection to clear, or nil for all
        def clear_cache(collection_name = nil)
          cache_mutex.synchronize do
            if collection_name
              index_cache.delete(collection_name)
            else
              @index_cache = {}
            end
          end
        end

        private

        # Mutex protecting @index_cache. Initialized lazily but the
        # initialization itself is guarded by a class-level mutex created at
        # load time, so two threads can't race on first access.
        CACHE_MUTEX_INIT = Mutex.new
        private_constant :CACHE_MUTEX_INIT

        def cache_mutex
          @cache_mutex ||= CACHE_MUTEX_INIT.synchronize { @cache_mutex ||= Mutex.new }
        end

        def index_cache
          @index_cache ||= {}
        end

        def cached_indexes(collection_name)
          index_cache.dig(collection_name, :indexes) || []
        end

        def cache_valid?(collection_name)
          entry = index_cache[collection_name]
          return false unless entry
          ttl = cache_ttl
          return false if ttl <= 0
          (Time.now - entry[:cached_at]) < ttl
        end

        def cache_indexes(collection_name, indexes)
          index_cache[collection_name] = {
            indexes: indexes,
            cached_at: Time.now,
          }
        end

        def handle_list_error(error, collection_name)
          msg = error.message.to_s.downcase
          if msg.include?("not available") ||
             msg.include?("atlas") ||
             msg.include?("command not found") ||
             msg.include?("unrecognized") ||
             msg.include?("not supported")
            raise NotAvailable,
              "Atlas Search is not available for collection '#{collection_name}'. " \
              "Ensure you're using MongoDB Atlas with Search enabled, or a local Atlas deployment. " \
              "Original error: #{error.message}"
          end
          raise error
        end
      end
    end
  end
end
