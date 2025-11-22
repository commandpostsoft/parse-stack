# encoding: UTF-8
# frozen_string_literal: true

require "time"
require "parallel"

module Parse
  # Combines a set of core functionality for {Parse::Object} and its subclasses.
  module Core
    # Defines the record fetching interface for instances of Parse::Object.
    module Fetching

      # Force fetches and updates the current object with the data contained in the Parse collection.
      # The changes applied to the object are not dirty tracked.
      # @param opts [Hash] a set of options to pass to the client request.
      # @return [self] the current object, useful for chaining.
      def fetch!(opts = {})
        response = client.fetch_object(parse_class, id, **opts)
        if response.error?
          puts "[Fetch Error] #{response.code}: #{response.error}"
          # Raise appropriate error based on response code
          case response.code
          when 101 # Object not found
            raise Parse::Error::ProtocolError, "Object not found"
          else
            raise Parse::Error::ProtocolError, response.error
          end
        end
        
        # Handle empty results gracefully - clear the object rather than error
        result = response.result
        if result.nil? || (result.is_a?(Array) && result.empty?)
          # Mark object as deleted and clear the ID
          @_deleted = true
          @id = nil
          clear_changes!
          return self
        end
        
        # If we successfully fetched data, ensure the object is not marked as deleted
        @_deleted = false
        
        # take the result hash and apply it to the attributes.
        apply_attributes!(result, dirty_track: false)

        # Clear partial fetch tracking - object is now fully fetched
        @_fetched_keys = nil
        @_nested_fetched_keys = nil

        begin
          clear_changes!
        rescue => e
          # If clear_changes! fails, manually reset change tracking
          @changed_attributes = {} if instance_variable_defined?(:@changed_attributes)
          @mutations_from_database = nil if instance_variable_defined?(:@mutations_from_database)
          @mutations_before_last_save = nil if instance_variable_defined?(:@mutations_before_last_save)
        end
        self
      end

      # Fetches the object from the Parse data store. Unlike fetchIfNeeded, this always
      # fetches from the server and updates the local object with fresh data.
      # @param returnObject [Boolean] if true (default), returns the Parse::Object; if false, returns JSON
      # @return [self] the current object when called without parameters, or a fetched object when returnObject=true.
      def fetch(returnObject = true)
        if returnObject
          fetch! # This always updates self with fresh data from server
          self   # Return the updated self
        else
          # Return the raw JSON data without updating the current object
          response = client.fetch_object(parse_class, id)
          return nil if response.error?
          response.result
        end
      end

      # Fetches the Parse object from the data store and returns a Parse::Object instance.
      # This is a convenience method that calls fetch(true).
      # @return [Parse::Object] the fetched Parse::Object (self if already fetched).
      def fetch_object
        fetch(true)
      end

      # Autofetches the object based on a key that is not part {Parse::Properties::BASE_KEYS}.
      # If the key is not a Parse standard key, and the current object is in a
      # Pointer state or was partially fetched, then fetch the data related to
      # this record from the Parse data store.
      # @param key [String] the name of the attribute being accessed.
      # @return [Boolean]
      def autofetch!(key)
        key = key.to_sym
        @fetch_lock ||= false
        # Autofetch if object is a pointer OR was partially fetched
        needs_fetch = pointer? || partially_fetched?
        if @fetch_lock != true && needs_fetch && key != :acl && Parse::Properties::BASE_KEYS.include?(key) == false && respond_to?(:fetch)
          #puts "AutoFetching Triggerd by: #{self.class}.#{key} (#{id})"
          @fetch_lock = true
          send :fetch
          @fetch_lock = false
        end
      end
    end
  end
end

class Array

  # Perform a threaded each iteration on a set of array items.
  # @param threads [Integer] the maximum number of threads to spawn/
  # @yield the block for the each iteration.
  # @return [self]
  # @see Array#each
  # @see https://github.com/grosser/parallel Parallel
  def threaded_each(threads = 2, &block)
    Parallel.each(self, { in_threads: threads }, &block)
  end

  # Perform a threaded map operation on a set of array items.
  # @param threads [Integer] the maximum number of threads to spawn
  # @yield the block for the map iteration.
  # @return [Array] the resultant array from the map.
  # @see Array#map
  # @see https://github.com/grosser/parallel Parallel
  def threaded_map(threads = 2, &block)
    Parallel.map(self, { in_threads: threads }, &block)
  end

  # Fetches all the objects in the array even if they are not in a Pointer state.
  # @param lookup [Symbol] The methodology to use for HTTP requests. Use :parallel
  #  to fetch all objects in parallel HTTP requests. Set to anything else to
  #  perform requests serially.
  # @return [Array<Parse::Object>] an array of fetched Parse::Objects.
  # @see Array#fetch_objects
  def fetch_objects!(lookup = :parallel)
    # this gets all valid parse objects from the array
    items = valid_parse_objects
    lookup == :parallel ? items.threaded_each(2, &:fetch!) : items.each(&:fetch!)
    #self.replace items
    self #return for chaining.
  end

  # Fetches all the objects in the array that are in Pointer state.
  # @param lookup [Symbol] The methodology to use for HTTP requests. Use :parallel
  #  to fetch all objects in parallel HTTP requests. Set to anything else to
  #  perform requests serially.
  # @return [Array<Parse::Object>] an array of fetched Parse::Objects.
  # @see Array#fetch_objects!
  def fetch_objects(lookup = :parallel)
    items = valid_parse_objects
    lookup == :parallel ? items.threaded_each(2, &:fetch) : items.each(&:fetch)
    #self.replace items
    self
  end
end
