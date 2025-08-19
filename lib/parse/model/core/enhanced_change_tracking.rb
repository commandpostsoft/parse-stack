# encoding: UTF-8
# frozen_string_literal: true

module Parse
  module Core
    # Enhanced change tracking for Parse::Object that provides consistent
    # access to _changed? and _was methods in both before_save and after_save hooks.
    #
    # This module overrides the ActiveModel-generated _changed? and _was methods
    # to use previous_changes when available, providing a consistent API across
    # all hook contexts.
    #
    # Key benefits:
    # - _changed? methods work correctly in after_save hooks  
    # - _was methods return actual previous values (not current values) in after_save
    # - Backwards compatible with existing code
    # - Automatically detects context using presence of previous_changes
    #
    # @example
    #   class Product < Parse::Object
    #     property :name, :string
    #     property :price, :float
    #     
    #     after_save :send_price_alert
    #     
    #     def send_price_alert
    #       if price_changed? && price_was < price
    #         AlertService.send("Price increased from $#{price_was} to $#{price}")
    #       end
    #     end
    #   end
    module EnhancedChangeTracking
      
      def self.included(base)
        base.extend(ClassMethods)
      end
      
      module ClassMethods
        # Override the property method to add enhanced change tracking
        # after the ActiveModel methods are defined
        def property(key, data_type = :string, **opts)
          result = super # Call the original property method
          
          # After property is defined, override the _changed? and _was methods
          enhance_change_tracking_for_field(key)
          
          result
        end
        
        private
        
        # Create enhanced versions of _changed? and _was methods for a field
        # @param field_name [Symbol] the field name to enhance
        def enhance_change_tracking_for_field(field_name)
          changed_method = "#{field_name}_changed?"
          was_method = "#{field_name}_was"
          
          # Store references to original methods if they exist
          original_changed_method = "__original_#{changed_method}".to_sym
          original_was_method = "__original_#{was_method}".to_sym
          
          # Alias original methods if they exist
          if instance_method_defined?(changed_method)
            alias_method original_changed_method, changed_method
          end
          if instance_method_defined?(was_method)
            alias_method original_was_method, was_method
          end
          
          # Define enhanced _changed? method
          define_method(changed_method) do
            enhanced_field_changed?(field_name.to_s)
          end
          
          # Define enhanced _was method
          define_method(was_method) do
            enhanced_field_was(field_name.to_s)
          end
        end
        
        # Check if an instance method is defined
        # @param method_name [String, Symbol] the method name
        # @return [Boolean] true if the method is defined
        def instance_method_defined?(method_name)
          method_defined?(method_name) || private_method_defined?(method_name)
        end
      end
      
      private
      
      # Enhanced implementation of field_changed? that works in all contexts
      # @param field_name [String] the name of the field to check
      # @return [Boolean] true if the field was changed, false otherwise
      def enhanced_field_changed?(field_name)
        # If previous_changes is available, use it for reliable change detection
        if previous_changes_available?
          return previous_changes.key?(field_name.to_s)
        end
        
        # Fallback to original ActiveModel method if available
        original_method = "__original_#{field_name}_changed?".to_sym
        if respond_to?(original_method, true)
          return send(original_method)
        end
        
        # Default fallback
        false
      end
      
      # Enhanced implementation of field_was that works in all contexts
      # @param field_name [String] the name of the field to get previous value for
      # @return [Object] the previous value of the field
      def enhanced_field_was(field_name)
        # If previous_changes is available, use it for reliable previous values
        if previous_changes_available?
          if previous_changes[field_name.to_s]
            return previous_changes[field_name.to_s][0] # [old_value, new_value]
          else
            # Field not in previous_changes = no change, return current value
            return send(field_name) if respond_to?(field_name)
          end
        end
        
        # Fallback to original ActiveModel method if available
        original_method = "__original_#{field_name}_was".to_sym
        if respond_to?(original_method, true)
          return send(original_method)
        end
        
        # Default fallback to current value
        respond_to?(field_name) ? send(field_name) : nil
      end
      
      # Check if previous_changes is available and populated
      # @return [Boolean] true if previous_changes is available
      def previous_changes_available?
        respond_to?(:previous_changes) && 
        previous_changes.is_a?(Hash) && 
        !previous_changes.empty?
      end
    end
  end
end