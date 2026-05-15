# encoding: UTF-8
# frozen_string_literal: true

require "active_support/concern"

module Parse
  module Core
    # Declarative self-referential identifier field for Parse::Object
    # subclasses. When `parse_reference` is declared on a class, every newly-
    # created instance gets a string field auto-populated with the canonical
    # `"ClassName$objectId"` form via an `after_create` callback. The value
    # mirrors Parse Server's internal pointer-column format (`_p_team` ->
    # `"Team$xyz"`), which makes direct MongoDB queries, `$lookup` joins, and
    # cross-class analytics trivial: a single equality match on one column.
    #
    # Mechanics:
    #
    # * The initial `save` creates the row and returns the server-assigned
    #   objectId. An after_create callback then sets the reference field and
    #   triggers a follow-up `save` — two REST round-trips per new object.
    #   The callback is a no-op on subsequent saves once the field matches
    #   the canonical value.
    # * The DSL is opt-in. Classes that don't call `parse_reference` get no
    #   field, no callback, and no extra writes.
    # * The field is logically constant once set (objectId and parse_class
    #   are both immutable for the object). The DSL auto-installs two
    #   protections:
    #   1. `protect_fields("*", [field_name])` so non-master clients never
    #      see the column on reads.
    #   2. `guard field_name, :set_once` so once the after_create populates
    #      the field, no further write (client or master) can change it.
    #      Master-key requests do NOT bypass `:set_once` once the value is
    #      present, so a buggy migration or admin script cannot corrupt
    #      the canonical reference.
    # * Inherits cleanly into `Parse::User`, `Parse::Installation`, and
    #   other system-class subclasses. The reference format becomes
    #   `"_User$objectId"`, `"_Installation$objectId"`, etc., matching
    #   Parse Server's own `_p_user`/`_p_installation` column format.
    # * Batch / transaction caveat: `Parse::Object.transaction` and
    #   `Parse::Object.save_all` set the server-assigned objectId via
    #   `instance_variable_set` without running the `:create` callback
    #   chain. Objects created through those paths therefore do NOT have
    #   the parse_reference auto-populated. Use the
    #   {ClassMethods#populate_parse_references!} batch helper or call
    #   `obj._assign_<field>!` manually after the transaction commits.
    #
    # @example default field name
    #   class Post < Parse::Object
    #     parse_reference   # local :parse_reference -> remote "parseReference"
    #   end
    #   post = Post.create(title: "Hi")
    #   post.parse_reference   # => "Post$abc123"
    #
    # @example custom local name
    #   class Event < Parse::Object
    #     parse_reference :ref
    #   end
    #
    # @example custom local AND remote names
    #   class Activity < Parse::Object
    #     parse_reference :ref, field: "refKey"
    #   end
    #
    # @example works on system class subclasses (for normal Parse::Object
    #   creates -- NOT for Parse::User#signup!, which goes through a
    #   distinct REST endpoint and does not run the `:create` callback
    #   chain. On a User subclass, populate the reference manually after
    #   signup: `user._assign_parse_reference!`.)
    #   class User < Parse::User
    #     parse_reference
    #   end
    module ParseReference
      extend ActiveSupport::Concern

      # The separator between class name and object id. Matches Parse Server's
      # own pointer-column format (e.g. `_p_team = "Team$abcd1234"`).
      SEPARATOR = "$".freeze

      # Build a canonical "Class$id" reference string. Returns nil if either
      # piece is blank — callers wiring this into other systems can use the
      # nil to skip writing the field.
      def self.format(parse_class, id)
        return nil if parse_class.to_s.empty? || id.to_s.empty?
        "#{parse_class}#{SEPARATOR}#{id}"
      end

      # Split a "Class$id" string into [class_name, object_id]. Returns
      # [nil, nil] for nil input; raises ArgumentError on malformed input
      # (anything else than a string containing the separator).
      def self.parse(string)
        return [nil, nil] if string.nil?
        unless string.is_a?(String) && string.include?(SEPARATOR)
          raise ArgumentError, "not a parse_reference: #{string.inspect}"
        end
        string.split(SEPARATOR, 2)
      end

      module ClassMethods
        # Declare a self-referential identifier field on this class.
        # See {Parse::Core::ParseReference} for full documentation.
        #
        # @param field_name [Symbol] local property name (default :parse_reference)
        # @param field [String, nil] remote Parse column name; defaults to the
        #   camelCased form of `field_name`
        # @return [Symbol] the registered field name
        def parse_reference(field_name = :parse_reference, field: nil)
          field_name = field_name.to_sym
          unless field_name.to_s =~ /\A[a-z_][a-z0-9_]*\z/i
            raise ArgumentError,
                  "parse_reference field name must match /\\A[a-z_][a-z0-9_]*\\z/i, got #{field_name.inspect}"
          end
          remote = field || field_name.to_s.camelize(:lower)
          property field_name, :string, field: remote

          # Auto-install read-side hiding: clients shouldn't see the
          # internal reference column. Master/admin reads (which is how
          # analytics queries and direct Mongo lookups run) are unaffected
          # because protect_fields("*", ...) only applies to non-master
          # reads. Merge into any existing "*" protected fields rather
          # than overwriting (the underlying set_protected_fields method
          # replaces by pattern).
          if respond_to?(:protect_fields) && respond_to?(:class_permissions)
            existing = class_permissions.protected_fields_for("*") rescue []
            merged = (existing + [field_name.to_s]).uniq
            protect_fields("*", merged)
          end

          # Auto-install write-side protection: once the after_create
          # populates the value, nothing (including master) can rewrite
          # it. :set_once allows the first transition from blank to a
          # value, then locks the field forever.
          if respond_to?(:guard)
            guard field_name, :set_once
          end

          # Define a helper that computes the canonical value and writes
          # via `update!` (bypassing the user's save/create callback
          # chain so this internal bookkeeping write doesn't double-fire
          # after_save hooks the user has on the class).
          method_name = :"_assign_#{field_name}!"
          define_method(method_name) do
            return unless id.present?
            target = Parse::Core::ParseReference.format(self.class.parse_class, id)
            return if public_send(field_name) == target
            public_send("#{field_name}=", target)
            ok = update!
            unless ok
              Parse.logger&.warn(
                "[Parse::ParseReference] Failed to persist #{self.class.parse_class}##{id} " \
                "#{field_name} = #{target.inspect}; object exists without its reference field. " \
                "errors=#{errors.full_messages.inspect rescue nil}"
              )
            end
            ok
          end

          # Expose the configured field name as a class-level reader so
          # the batch-populate helper and other introspection code can
          # find it without re-parsing the class body.
          @_parse_reference_fields ||= []
          @_parse_reference_fields << field_name
          singleton_class.send(:attr_reader, :_parse_reference_fields) unless singleton_class.method_defined?(:_parse_reference_fields)

          # Register the after_create callback, but only if this exact
          # method isn't already in the callback chain. Re-declaration in a
          # subclass (or accidental double-declaration in the same class)
          # otherwise stacks multiple invocations and produces multiple
          # extra REST writes per create. The check inspects the chain by
          # filter name so it correctly handles both fresh registration
          # and inheritance from a parent that already declared.
          already_registered = _create_callbacks.any? do |cb|
            (cb.filter.to_sym rescue cb.filter) == method_name
          end
          after_create method_name unless already_registered
          field_name
        end

        # Populate the parse_reference field for an array of already-saved
        # objects. Use after `Parse::Object.transaction` or `save_all`
        # (both of which bypass the `:create` callback chain) so the
        # canonical reference still lands in MongoDB. Each object gets an
        # individual `update!` call -- callers wanting tighter batching
        # can wrap multiple updates in their own `Parse::Object.transaction`.
        #
        # Objects that already have a populated reference, or that lack an
        # objectId, are skipped silently.
        #
        # @example
        #   posts = []
        #   Post.transaction do |batch|
        #     3.times { posts << Post.new(title: "hi").tap { |p| batch.add(p) } }
        #   end
        #   Post.populate_parse_references!(posts)   # second round-trip per object
        #
        # @param objects [Array<Parse::Object>] objects to populate
        # @return [Array<Parse::Object>] the objects that were updated
        def populate_parse_references!(objects)
          return [] if objects.nil? || objects.empty?
          fields_to_populate = Array(@_parse_reference_fields)
          return [] if fields_to_populate.empty?
          updated = []
          objects.each do |obj|
            next unless obj.is_a?(self) && obj.id.present?
            changed_any = false
            fields_to_populate.each do |field_name|
              method = :"_assign_#{field_name}!"
              next unless obj.respond_to?(method)
              before = obj.public_send(field_name)
              obj.public_send(method)
              changed_any ||= (obj.public_send(field_name) != before)
            end
            updated << obj if changed_any
          end
          updated
        end
      end
    end
  end
end
