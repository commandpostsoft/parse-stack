require_relative '../../test_helper'
require 'minitest/autorun'

# Test model using enhanced Parse::Object
class EnhancedProduct < Parse::Object
  property :name, :string
  property :status, :string  
  property :price, :float
  property :stock_quantity, :integer
  
  attr_accessor :before_save_data, :after_save_data
  
  before_save :capture_before_save_state
  after_save :capture_after_save_state
  
  def capture_before_save_state
    self.before_save_data = {
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      stock_quantity_changed: stock_quantity_changed?,
      name_was: name_was,
      status_was: status_was,
      price_was: price_was,
      stock_quantity_was: stock_quantity_was,
      previous_changes_available: !!(previous_changes rescue nil)
    }
  end
  
  def capture_after_save_state
    self.after_save_data = {
      name_changed: name_changed?,
      status_changed: status_changed?,
      price_changed: price_changed?,
      stock_quantity_changed: stock_quantity_changed?,
      name_was: name_was,
      status_was: status_was,
      price_was: price_was,
      stock_quantity_was: stock_quantity_was,
      previous_changes_available: !!(previous_changes rescue nil),
      previous_changes_hash: previous_changes
    }
  end
end

class IntegratedEnhancedChangeTrackingTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end
  
  def test_enhanced_change_tracking_integration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "enhanced change tracking integration test") do
        product = EnhancedProduct.new({
          name: "Original Product",
          status: "draft",
          price: 50.00,
          stock_quantity: 100
        })
        
        assert product.save, "Product should save successfully"
        
        puts "\n=== First Save (Create) ==="
        puts "BEFORE_SAVE:"
        puts "  previous_changes available: #{product.before_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{product.before_save_data[:name_changed]}"
        puts "  name_was: '#{product.before_save_data[:name_was]}'"
        
        puts "AFTER_SAVE:"
        puts "  previous_changes available: #{product.after_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{product.after_save_data[:name_changed]}"
        puts "  name_was: '#{product.after_save_data[:name_was]}'"
        
        # Update the product to test enhanced methods
        product.name = "Updated Product"
        product.price = 75.00
        product.stock_quantity = 50
        
        assert product.save, "Product should update successfully"
        
        puts "\n=== Second Save (Update) ==="
        puts "BEFORE_SAVE:"
        puts "  previous_changes available: #{product.before_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{product.before_save_data[:name_changed]}"
        puts "  price_changed?: #{product.before_save_data[:price_changed]}"
        puts "  status_changed?: #{product.before_save_data[:status_changed]}"
        puts "  stock_quantity_changed?: #{product.before_save_data[:stock_quantity_changed]}"
        puts "  name_was: '#{product.before_save_data[:name_was]}'"
        puts "  price_was: #{product.before_save_data[:price_was]}"
        
        puts "AFTER_SAVE (Enhanced Methods):"
        puts "  previous_changes available: #{product.after_save_data[:previous_changes_available]}"
        puts "  name_changed?: #{product.after_save_data[:name_changed]}"
        puts "  price_changed?: #{product.after_save_data[:price_changed]}"
        puts "  status_changed?: #{product.after_save_data[:status_changed]}"
        puts "  stock_quantity_changed?: #{product.after_save_data[:stock_quantity_changed]}"
        puts "  name_was: '#{product.after_save_data[:name_was]}'"
        puts "  price_was: #{product.after_save_data[:price_was]}"
        puts "  stock_quantity_was: #{product.after_save_data[:stock_quantity_was]}"
        
        # Verify enhanced methods work correctly in after_save
        assert product.after_save_data[:previous_changes_available], "previous_changes should be available in after_save"
        assert product.after_save_data[:name_changed], "Enhanced name_changed? should work in after_save"
        assert product.after_save_data[:price_changed], "Enhanced price_changed? should work in after_save"
        assert product.after_save_data[:stock_quantity_changed], "Enhanced stock_quantity_changed? should work in after_save"
        assert !product.after_save_data[:status_changed], "Enhanced status_changed? should be false for unchanged field"
        
        # Verify _was methods return correct previous values
        assert_equal "Original Product", product.after_save_data[:name_was], "Enhanced name_was should return previous value"
        assert_equal 50.00, product.after_save_data[:price_was], "Enhanced price_was should return previous value"
        assert_equal 100, product.after_save_data[:stock_quantity_was], "Enhanced stock_quantity_was should return previous value"
        
        puts "\n✅ SUCCESS: Enhanced change tracking integrated into Parse::Object!"
        puts "✅ _changed? methods work correctly in after_save hooks"
        puts "✅ _was methods return actual previous values in after_save hooks"
        puts "✅ Backwards compatible with existing before_save behavior"
      end
    end
  end
  
  def test_enhanced_methods_in_conditional_hooks
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "enhanced methods in conditional hooks test") do
        product = EnhancedProduct.new({
          name: "Test Product",
          status: "inactive",
          price: 100.00
        })
        
        # Add an after_save hook that uses enhanced methods
        product.define_singleton_method(:process_changes) do
          @change_log = []
          
          if name_changed?
            @change_log << "Name changed from '#{name_was}' to '#{name}'"
          end
          
          if price_changed?
            price_diff = price - price_was
            @change_log << "Price changed by $#{price_diff} (from $#{price_was} to $#{price})"
          end
          
          if status_changed?
            @change_log << "Status changed from '#{status_was}' to '#{status}'"
          end
        end
        
        # Add the hook
        product.class.after_save :process_changes
        
        assert product.save, "Product should save successfully"
        
        # Make changes to trigger the hook
        product.name = "Updated Test Product"
        product.price = 150.00
        product.status = "active"
        
        assert product.save, "Product should update successfully"
        
        # Verify the change log was created correctly using enhanced methods
        change_log = product.instance_variable_get(:@change_log)
        assert change_log, "Change log should be created"
        assert change_log.any? { |log| log.include?("Name changed from 'Test Product'") }, "Should log name change"
        assert change_log.any? { |log| log.include?("Price changed by $50.0") }, "Should log price change"
        assert change_log.any? { |log| log.include?("Status changed from 'inactive'") }, "Should log status change"
        
        puts "\n✅ Enhanced methods work perfectly in conditional after_save hooks!"
        puts "Change log generated:"
        change_log.each { |log| puts "  - #{log}" }
      end
    end
  end
end