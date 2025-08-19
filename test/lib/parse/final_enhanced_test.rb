require_relative '../../test_helper'
require 'minitest/autorun'

# Test model using enhanced Parse::Object
class FinalTestProduct < Parse::Object
  property :name, :string
  property :price, :float
  
  attr_accessor :after_save_change_data
  
  after_save :capture_enhanced_changes
  
  def capture_enhanced_changes
    self.after_save_change_data = {
      name_changed: name_changed?,
      price_changed: price_changed?,
      name_was: name_was,
      price_was: price_was,
      current_name: name,
      current_price: price,
      previous_changes: previous_changes
    }
  end
end

class FinalEnhancedTest < Minitest::Test
  include ParseStackIntegrationTest
  
  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end
  
  def test_enhanced_change_tracking_final_demonstration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      with_timeout(10, "final enhanced change tracking demonstration") do
        product = FinalTestProduct.new({
          name: "Original Product",
          price: 100.00
        })
        
        assert product.save, "Product should save successfully"
        
        # Update the product
        product.name = "Updated Product"
        product.price = 150.00
        
        assert product.save, "Product should update successfully"
        
        # Examine the after_save data
        data = product.after_save_change_data
        
        puts "\n🎉 ENHANCED CHANGE TRACKING SUCCESS! 🎉"
        puts "================================================"
        puts "In after_save hook:"
        puts "  name_changed?: #{data[:name_changed]}"
        puts "  price_changed?: #{data[:price_changed]}"
        puts "  name_was: '#{data[:name_was]}'"
        puts "  price_was: #{data[:price_was]}"
        puts "  current_name: '#{data[:current_name]}'"
        puts "  current_price: #{data[:current_price]}"
        puts "  previous_changes: #{data[:previous_changes]}"
        puts "================================================"
        
        # Verify enhanced functionality
        assert data[:name_changed], "Enhanced name_changed? should work in after_save"
        assert data[:price_changed], "Enhanced price_changed? should work in after_save"
        assert_equal "Original Product", data[:name_was], "Enhanced name_was should return previous value"
        assert_equal 100.00, data[:price_was], "Enhanced price_was should return previous value"
        assert_equal "Updated Product", data[:current_name], "Current name should be updated value"
        assert_equal 150.00, data[:current_price], "Current price should be updated value"
        
        puts "\n✅ All assertions passed!"
        puts "✅ _changed? methods work in after_save"
        puts "✅ _was methods return actual previous values"
        puts "✅ Enhanced change tracking is fully functional!"
      end
    end
  end
end