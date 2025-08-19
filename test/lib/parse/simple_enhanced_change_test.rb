require_relative '../../test_helper'
require 'minitest/autorun'

# Simple Enhanced Parse::Object with improved _changed? and _was methods
class SimpleEnhancedParse < Parse::Object
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
class SimpleTestItem < SimpleEnhancedParse
  property :name, :string
  property :status, :string
  property :price, :float
  
  attr_accessor :before_save_data, :after_save_data
  
  before_save :capture_before_save_state
  after_save :capture_after_save_state
  
  def capture_before_save_state
    self.before_save_data = {
      context: "before_save",
      previous_changes_available: !!(previous_changes rescue nil),
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      name_was: name_was,
      status_was: status_was,
      price_was: price_was
    }
  end
  
  def capture_after_save_state
    self.after_save_data = {
      context: "after_save", 
      previous_changes_available: !!(previous_changes rescue nil),
      previous_changes_hash: previous_changes,
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      name_was: name_was,
      status_was: status_was,
      price_was: price_was
    }
  end
end

class SimpleEnhancedChangeTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end
  
  def test_enhanced_change_tracking_proof_of_concept
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "enhanced change tracking proof of concept") do
        item = SimpleTestItem.new({
          name: "Original Name",
          status: "draft",
          price: 100.00
        })
        
        assert item.save, "Item should save successfully"
        
        puts "\n=== First Save (Create) ==="
        puts "BEFORE_SAVE:"
        puts "  previous_changes available: #{item.before_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{item.before_save_data[:name_changed]}"
        puts "  name_was: #{item.before_save_data[:name_was]}"
        
        puts "AFTER_SAVE:"
        puts "  previous_changes available: #{item.after_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{item.after_save_data[:name_changed]}"
        puts "  name_was: #{item.after_save_data[:name_was]}"
        
        # Update the item to test enhanced methods
        item.name = "Updated Name"
        item.price = 150.00
        
        assert item.save, "Item should update successfully"
        
        puts "\n=== Second Save (Update) ==="
        puts "BEFORE_SAVE:"
        puts "  previous_changes available: #{item.before_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{item.before_save_data[:name_changed]}"
        puts "  price_changed?: #{item.before_save_data[:price_changed]}"
        puts "  status_changed?: #{item.before_save_data[:status_changed]}"
        puts "  name_was: #{item.before_save_data[:name_was]}"
        puts "  price_was: #{item.before_save_data[:price_was]}"
        
        puts "AFTER_SAVE:"
        puts "  previous_changes available: #{item.after_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{item.after_save_data[:name_changed]}" 
        puts "  price_changed?: #{item.after_save_data[:price_changed]}"
        puts "  status_changed?: #{item.after_save_data[:status_changed]}"
        puts "  name_was: #{item.after_save_data[:name_was]}"
        puts "  price_was: #{item.after_save_data[:price_was]}"
        puts "  actual previous_changes: #{item.after_save_data[:previous_changes_hash]}"
        
        # Verify that enhanced methods work correctly
        
        # In before_save: previous_changes not available, use original methods
        assert !item.before_save_data[:previous_changes_available], "previous_changes should not be available in before_save"
        assert item.before_save_data[:name_changed], "name_changed? should work in before_save"
        assert item.before_save_data[:price_changed], "price_changed? should work in before_save"
        assert !item.before_save_data[:status_changed], "status_changed? should be false for unchanged field"
        assert_equal "Original Name", item.before_save_data[:name_was], "name_was should work in before_save"
        assert_equal 100.00, item.before_save_data[:price_was], "price_was should work in before_save"
        
        # In after_save: previous_changes available, use enhanced methods
        assert item.after_save_data[:previous_changes_available], "previous_changes should be available in after_save"
        assert item.after_save_data[:name_changed], "Enhanced name_changed? should work in after_save"
        assert item.after_save_data[:price_changed], "Enhanced price_changed? should work in after_save"
        assert !item.after_save_data[:status_changed], "Enhanced status_changed? should be false for unchanged field"
        assert_equal "Original Name", item.after_save_data[:name_was], "Enhanced name_was should work in after_save"
        assert_equal 100.00, item.after_save_data[:price_was], "Enhanced price_was should work in after_save"
        
        puts "\n✅ SUCCESS: Enhanced _changed? and _was methods working!"
        puts "✅ Context detection via previous_changes presence works perfectly"
        puts "✅ before_save uses original methods, after_save uses previous_changes"
      end
    end
  end
end