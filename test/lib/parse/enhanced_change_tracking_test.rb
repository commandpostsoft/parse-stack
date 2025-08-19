require_relative '../../test_helper'
require 'minitest/autorun'

# Enhanced Parse::Object with improved _changed? and _was methods
class EnhancedParse < Parse::Object
  # Override _changed? methods to work in after_save using previous_changes
  def method_missing(method_name, *args, &block)
    if method_name.to_s.end_with?('_changed?')
      field_name = method_name.to_s.gsub('_changed?', '')
      return enhanced_field_changed?(field_name)
    elsif method_name.to_s.end_with?('_was')
      field_name = method_name.to_s.gsub('_was', '')
      return enhanced_field_was(field_name)
    end
    
    super
  end
  
  def respond_to_missing?(method_name, include_private = false)
    method_name.to_s.end_with?('_changed?') || 
    method_name.to_s.end_with?('_was') || 
    super
  end
  
  private
  
  def enhanced_field_changed?(field_name)
    # If previous_changes exists, we're in after_save context
    if previous_changes && respond_to?(:previous_changes)
      previous_changes.key?(field_name.to_s)
    else
      # In before_save context, use original method
      original_method = "#{field_name}_changed?".to_sym
      if respond_to?(original_method)
        send(original_method)
      else
        false
      end
    end
  end
  
  def enhanced_field_was(field_name)
    # If previous_changes exists, we're in after_save context
    if previous_changes && respond_to?(:previous_changes)
      if previous_changes[field_name.to_s]
        previous_changes[field_name.to_s][0] # Return old value
      else
        send(field_name) # Return current value if no change
      end
    else
      # In before_save context, use original method
      original_method = "#{field_name}_was".to_sym
      if respond_to?(original_method)
        send(original_method)
      else
        nil
      end
    end
  end
end

# Test model using the enhanced base class
class EnhancedTestItem < EnhancedParse
  property :name, :string
  property :status, :string
  property :price, :float
  property :quantity, :integer
  
  attr_accessor :before_save_changes, :after_save_changes, 
                :before_save_was_values, :after_save_was_values
  
  before_save :capture_before_save_state
  after_save :capture_after_save_state
  
  def capture_before_save_state
    self.before_save_changes = {
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      quantity_changed: quantity_changed?
    }
    
    self.before_save_was_values = {
      name_was: name_was,
      status_was: status_was,
      price_was: price_was,
      quantity_was: quantity_was
    }
  end
  
  def capture_after_save_state
    self.after_save_changes = {
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      quantity_changed: quantity_changed?
    }
    
    self.after_save_was_values = {
      name_was: name_was,
      status_was: status_was,
      price_was: price_was,
      quantity_was: quantity_was
    }
  end
end

class EnhancedChangeTrackingTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end
  
  def test_enhanced_changed_methods_in_after_save
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "enhanced _changed? methods test") do
        item = EnhancedTestItem.new({
          name: "Original Item",
          status: "pending",
          price: 100.00,
          quantity: 5
        })
        
        assert item.save, "Item should save successfully"
        
        puts "\n=== First Save (Create) ==="
        puts "Before save - name_changed?: #{item.before_save_changes[:name_changed]}"
        puts "After save - name_changed?: #{item.after_save_changes[:name_changed]}"
        puts "Before save - name_was: #{item.before_save_was_values[:name_was]}"
        puts "After save - name_was: #{item.after_save_was_values[:name_was]}"
        
        # Update the item
        item.name = "Updated Item"
        item.status = "active" 
        item.price = 150.00
        
        assert item.save, "Item should update successfully"
        
        puts "\n=== Second Save (Update) ==="
        puts "Before save - name_changed?: #{item.before_save_changes[:name_changed]}"
        puts "After save - name_changed?: #{item.after_save_changes[:name_changed]}"
        puts "Before save - name_was: #{item.before_save_was_values[:name_was]}"
        puts "After save - name_was: #{item.after_save_was_values[:name_was]}"
        
        # Test that after_save now shows correct _changed? values
        assert item.after_save_changes[:name_changed], "name_changed? should be true in after_save"
        assert item.after_save_changes[:status_changed], "status_changed? should be true in after_save"
        assert item.after_save_changes[:price_changed], "price_changed? should be true in after_save"
        assert !item.after_save_changes[:quantity_changed], "quantity_changed? should be false in after_save"
        
        # Test that after_save shows correct _was values  
        assert_equal "Original Item", item.after_save_was_values[:name_was], "name_was should show previous value"
        assert_equal "pending", item.after_save_was_values[:status_was], "status_was should show previous value"
        assert_equal 100.00, item.after_save_was_values[:price_was], "price_was should show previous value"
        assert_equal 5, item.after_save_was_values[:quantity_was], "quantity_was should show unchanged value"
        
        puts "\n✓ Enhanced _changed? and _was methods working in after_save!"
      end
    end
  end
  
  def test_enhanced_methods_work_in_before_save_too
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "enhanced methods in before_save test") do
        item = EnhancedTestItem.new({
          name: "Test Item",
          status: "draft",
          price: 50.00
        })
        
        # Add a before_save hook to verify previous_changes is not available
        item.define_singleton_method(:verify_context) do
          @previous_changes_available_in_before_save = !!(previous_changes rescue nil)
        end
        item.class.before_save :verify_context
        
        assert item.save, "Item should save successfully"
        
        # Verify previous_changes is not available in before_save
        assert !item.instance_variable_get(:@previous_changes_available_in_before_save), 
               "previous_changes should not be available in before_save"
        
        # Update for testing before_save
        item.name = "Modified Item"
        item.price = 75.00
        
        assert item.save, "Item should update successfully"
        
        # Verify before_save context still works correctly
        assert item.before_save_changes[:name_changed], "name_changed? should work in before_save"
        assert item.before_save_changes[:price_changed], "price_changed? should work in before_save"
        assert !item.before_save_changes[:status_changed], "status_changed? should be false for unchanged field"
        
        assert_equal "Test Item", item.before_save_was_values[:name_was], "name_was should work in before_save"
        assert_equal 50.00, item.before_save_was_values[:price_was], "price_was should work in before_save"
        
        puts "\n✓ Enhanced methods work correctly in before_save context"
        puts "✓ previous_changes detection correctly identifies context"
      end
    end
  end
  
  def test_conditional_hooks_with_enhanced_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "conditional hooks with enhanced methods test") do
        # Create a test model with hooks using the enhanced methods
        enhanced_item = EnhancedTestItem.new({
          name: "Hook Test Item",
          status: "inactive",
          price: 25.00
        })
        
        # Add conditional hooks that use _changed? and _was
        enhanced_item.define_singleton_method(:process_status_change) do
          if status_changed?
            puts "Status changed from #{status_was} to #{status} (detected in after_save)"
            @status_change_processed = true
          end
        end
        
        enhanced_item.define_singleton_method(:process_price_change) do
          if price_changed?
            @price_change_amount = price - price_was
            puts "Price changed by $#{@price_change_amount} (from $#{price_was} to $#{price})"
          end
        end
        
        # Add the hooks
        enhanced_item.class.after_save :process_status_change
        enhanced_item.class.after_save :process_price_change
        
        assert enhanced_item.save, "Item should save successfully"
        
        # Make changes to trigger hooks
        enhanced_item.status = "active"
        enhanced_item.price = 40.00
        
        assert enhanced_item.save, "Item should update successfully"
        
        # Verify hooks fired with correct change detection
        assert enhanced_item.instance_variable_get(:@status_change_processed), "Status change should be processed"
        assert_equal 15.00, enhanced_item.instance_variable_get(:@price_change_amount), "Price change amount should be calculated"
        
        puts "\n✓ Conditional hooks work seamlessly with enhanced _changed? and _was methods"
      end
    end
  end
end