require_relative '../../test_helper_integration'

# Test models for aggregation grouping testing
class AggregationProduct < Parse::Object
  parse_class "AggregationProduct"
  
  property :name, :string
  property :category, :string
  property :price, :float
  property :tags, :array
  property :metadata, :object
  property :launch_date, :date
  property :in_stock, :boolean, default: true
end

class AggregationSale < Parse::Object
  parse_class "AggregationSale"
  
  property :product_name, :string
  property :quantity, :integer
  property :revenue, :float
  property :sale_date, :date
  property :customer_regions, :array
  property :payment_methods, :array
end

class AggregationGroupingIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_sortable_grouping_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "sortable grouping test") do
        puts "\n=== Testing Sortable Grouping Functionality ==="

        # Create test products with different categories and prices
        products = [
          { name: "Laptop Pro", category: "electronics", price: 1299.99, tags: ["computer", "work"], launch_date: Date.new(2023, 6, 15) },
          { name: "Smartphone X", category: "electronics", price: 899.99, tags: ["phone", "mobile"], launch_date: Date.new(2023, 8, 20) },
          { name: "Coffee Mug", category: "kitchen", price: 15.99, tags: ["drink", "ceramic"], launch_date: Date.new(2023, 3, 10) },
          { name: "Desk Chair", category: "furniture", price: 249.99, tags: ["office", "comfort"], launch_date: Date.new(2023, 5, 5) },
          { name: "Gaming Mouse", category: "electronics", price: 79.99, tags: ["gaming", "computer"], launch_date: Date.new(2023, 7, 12) },
          { name: "Table Lamp", category: "furniture", price: 89.99, tags: ["lighting", "home"], launch_date: Date.new(2023, 4, 18) },
          { name: "Headphones", category: "electronics", price: 199.99, tags: ["audio", "wireless"], launch_date: Date.new(2023, 9, 3) }
        ]

        products.each do |product_data|
          product = AggregationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Test basic sortable grouping by category
        puts "Testing basic sortable grouping by category..."
        sortable_group = AggregationProduct.query.sortable_group_by(:category)
        results = sortable_group.results

        assert results.is_a?(Array), "Results should be an array"
        assert results.length >= 3, "Should have at least 3 categories"
        
        # Verify structure of sortable grouping results
        electronics_group = results.find { |group| group["_id"] == "electronics" }
        assert electronics_group, "Should have electronics group"
        assert electronics_group["count"] >= 4, "Electronics should have at least 4 products"
        assert electronics_group.key?("results"), "Should have results array"
        assert electronics_group["results"].is_a?(Array), "Results should be an array"

        # Test that results are properly sorted within groups (by default sort field)
        electronics_products = electronics_group["results"]
        assert electronics_products.length >= 4, "Electronics group should have products"
        electronics_products.each do |product|
          assert_equal "electronics", product["category"], "All products should be electronics"
          assert product["name"].present?, "Product should have name"
          assert product["price"].present?, "Product should have price"
        end

        puts "✅ Basic sortable grouping works correctly"

        # Test sortable grouping with custom sort options
        puts "Testing sortable grouping with custom sort options..."
        sorted_by_price = AggregationProduct.query.sortable_group_by(:category, sortable: { price: -1 })
        price_sorted_results = sorted_by_price.results

        electronics_sorted = price_sorted_results.find { |group| group["_id"] == "electronics" }["results"]
        prices = electronics_sorted.map { |p| p["price"] }
        assert_equal prices, prices.sort.reverse, "Products should be sorted by price descending"

        puts "✅ Custom sort options work correctly"

        # Test sortable grouping with additional aggregation stages
        puts "Testing sortable grouping with aggregation pipeline..."
        expensive_products = AggregationProduct.query
                                              .where(:price.gt => 100)
                                              .sortable_group_by(:category, sortable: { launch_date: -1 })
        expensive_results = expensive_products.results

        expensive_results.each do |group|
          group["results"].each do |product|
            assert product["price"] > 100, "All products should be expensive"
          end
          # Check launch_date sorting within group
          dates = group["results"].map { |p| Date.parse(p["launch_date"]["iso"]) }
          assert_equal dates, dates.sort.reverse, "Products should be sorted by launch_date descending"
        end

        puts "✅ Sortable grouping with pipeline constraints works correctly"
      end
    end
  end

  def test_flatten_arrays_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "flatten arrays test") do
        puts "\n=== Testing Flatten Arrays Functionality ==="

        # Create test sales with array fields
        sales = [
          { 
            product_name: "Laptop Pro", 
            quantity: 2, 
            revenue: 2599.98,
            sale_date: Date.new(2023, 9, 15),
            customer_regions: ["north", "west"],
            payment_methods: ["credit", "paypal"]
          },
          { 
            product_name: "Smartphone X", 
            quantity: 1, 
            revenue: 899.99,
            sale_date: Date.new(2023, 9, 16),
            customer_regions: ["south", "east", "central"],
            payment_methods: ["credit"]
          },
          { 
            product_name: "Coffee Mug", 
            quantity: 5, 
            revenue: 79.95,
            sale_date: Date.new(2023, 9, 17),
            customer_regions: ["north"],
            payment_methods: ["cash", "debit", "credit"]
          }
        ]

        sales.each do |sale_data|
          sale = AggregationSale.new(sale_data)
          assert sale.save, "Sale for #{sale_data[:product_name]} should save"
        end

        # Test flatten_arrays on customer_regions field
        puts "Testing flatten_arrays on customer_regions..."
        flattened_regions = AggregationSale.query.group_by(:customer_regions, flatten_arrays: true)
        region_results = flattened_regions.results

        assert region_results.is_a?(Array), "Results should be an array"
        
        # Should have individual regions as separate groups
        region_names = region_results.map { |group| group["_id"] }
        expected_regions = ["north", "west", "south", "east", "central"]
        expected_regions.each do |region|
          assert_includes region_names, region, "Should have #{region} as a separate group"
        end

        # Verify counts - north appears in 2 sales, others appear in 1 each
        north_group = region_results.find { |group| group["_id"] == "north" }
        assert_equal 2, north_group["count"], "North region should appear in 2 sales"

        west_group = region_results.find { |group| group["_id"] == "west" }
        assert_equal 1, west_group["count"], "West region should appear in 1 sale"

        puts "✅ Flatten arrays on customer_regions works correctly"

        # Test flatten_arrays on payment_methods field
        puts "Testing flatten_arrays on payment_methods..."
        flattened_payments = AggregationSale.query.group_by(:payment_methods, flatten_arrays: true)
        payment_results = flattened_payments.results

        payment_names = payment_results.map { |group| group["_id"] }
        expected_payments = ["credit", "paypal", "cash", "debit"]
        expected_payments.each do |payment|
          assert_includes payment_names, payment, "Should have #{payment} as a separate group"
        end

        # Credit appears in all 3 sales
        credit_group = payment_results.find { |group| group["_id"] == "credit" }
        assert_equal 3, credit_group["count"], "Credit should appear in 3 sales"

        # PayPal, cash, debit each appear in 1 sale
        paypal_group = payment_results.find { |group| group["_id"] == "paypal" }
        assert_equal 1, paypal_group["count"], "PayPal should appear in 1 sale"

        puts "✅ Flatten arrays on payment_methods works correctly"

        # Test flatten_arrays with additional constraints
        puts "Testing flatten_arrays with query constraints..."
        high_value_regions = AggregationSale.query
                                          .where(:revenue.gt => 500)
                                          .group_by(:customer_regions, flatten_arrays: true)
        high_value_results = high_value_regions.results

        # Should only include regions from high-value sales (Laptop Pro and Smartphone X)
        high_value_region_names = high_value_results.map { |group| group["_id"] }
        assert_includes high_value_region_names, "north", "Should include north (from laptop)"
        assert_includes high_value_region_names, "west", "Should include west (from laptop)"
        assert_includes high_value_region_names, "south", "Should include south (from smartphone)"
        refute_includes high_value_region_names, "central", "Should not include central if only from low-value sales"

        puts "✅ Flatten arrays with constraints works correctly"
      end
    end
  end

  def test_group_by_date_functionality
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(25, "group by date test") do
        puts "\n=== Testing Group By Date Functionality ==="

        # Create test sales across different dates and times
        sales_data = [
          { product_name: "Morning Sale 1", quantity: 1, revenue: 100.0, sale_date: DateTime.new(2023, 9, 15, 9, 30) },
          { product_name: "Morning Sale 2", quantity: 2, revenue: 200.0, sale_date: DateTime.new(2023, 9, 15, 10, 45) },
          { product_name: "Afternoon Sale", quantity: 1, revenue: 150.0, sale_date: DateTime.new(2023, 9, 15, 14, 20) },
          { product_name: "Next Day Sale 1", quantity: 3, revenue: 300.0, sale_date: DateTime.new(2023, 9, 16, 11, 15) },
          { product_name: "Next Day Sale 2", quantity: 1, revenue: 75.0, sale_date: DateTime.new(2023, 9, 16, 16, 45) },
          { product_name: "Weekend Sale", quantity: 2, revenue: 250.0, sale_date: DateTime.new(2023, 9, 17, 12, 0) },
          { product_name: "Next Week Sale", quantity: 1, revenue: 120.0, sale_date: DateTime.new(2023, 9, 22, 10, 30) }
        ]

        sales_data.each do |sale_data|
          sale = AggregationSale.new(sale_data)
          assert sale.save, "Sale #{sale_data[:product_name]} should save"
        end

        # Test daily grouping
        puts "Testing daily grouping..."
        daily_sales = AggregationSale.query.group_by_date(:sale_date, :day)
        daily_results = daily_sales.results

        assert daily_results.is_a?(Array), "Results should be an array"
        assert daily_results.length >= 4, "Should have at least 4 different days"

        # Verify daily grouping structure
        daily_results.each do |group|
          assert group.key?("_id"), "Each group should have _id"
          assert group.key?("count"), "Each group should have count"
          
          # Check date structure for daily grouping
          date_id = group["_id"]
          if date_id.is_a?(Hash)
            assert date_id.key?("year"), "Daily grouping should include year"
            assert date_id.key?("month"), "Daily grouping should include month"
            assert date_id.key?("day"), "Daily grouping should include day"
          end
        end

        # Find September 15th group (should have 3 sales)
        sept_15_group = daily_results.find do |group|
          date_id = group["_id"]
          date_id.is_a?(Hash) && 
          date_id["year"] == 2023 && 
          date_id["month"] == 9 && 
          date_id["day"] == 15
        end
        
        if sept_15_group
          assert_equal 3, sept_15_group["count"], "September 15th should have 3 sales"
        end

        puts "✅ Daily grouping works correctly"

        # Test monthly grouping
        puts "Testing monthly grouping..."
        monthly_sales = AggregationSale.query.group_by_date(:sale_date, :month)
        monthly_results = monthly_sales.results

        # All sales are in September 2023, so should have 1 group
        assert monthly_results.length >= 1, "Should have at least 1 month group"
        
        september_group = monthly_results.find do |group|
          date_id = group["_id"]
          date_id.is_a?(Hash) && 
          date_id["year"] == 2023 && 
          date_id["month"] == 9
        end
        
        if september_group
          assert_equal 7, september_group["count"], "September 2023 should have all 7 sales"
        end

        puts "✅ Monthly grouping works correctly"

        # Test hourly grouping
        puts "Testing hourly grouping..."
        hourly_sales = AggregationSale.query.group_by_date(:sale_date, :hour)
        hourly_results = hourly_sales.results

        assert hourly_results.length >= 6, "Should have multiple hour groups"
        
        # Verify hourly structure includes hour field
        hourly_results.each do |group|
          date_id = group["_id"]
          if date_id.is_a?(Hash)
            assert date_id.key?("hour"), "Hourly grouping should include hour"
          end
        end

        puts "✅ Hourly grouping works correctly"

        # Test group_by_date with return_pointers option
        puts "Testing group_by_date with return_pointers..."
        daily_with_pointers = AggregationSale.query.group_by_date(:sale_date, :day, return_pointers: true)
        pointer_results = daily_with_pointers.results

        assert pointer_results.is_a?(Array), "Results should be an array"
        pointer_results.each do |group|
          assert group.key?("count"), "Should have count"
          if group.key?("results")
            group["results"].each do |result|
              # When return_pointers is true, results should be minimal pointer-like objects
              assert result.key?("objectId"), "Should have objectId for pointer"
              assert result.key?("__type"), "Should have __type for pointer"
            end
          end
        end

        puts "✅ Group by date with return_pointers works correctly"

        # Test group_by_date with constraints
        puts "Testing group_by_date with query constraints..."
        high_revenue_daily = AggregationSale.query
                                          .where(:revenue.gt => 150)
                                          .group_by_date(:sale_date, :day)
        constrained_results = high_revenue_daily.results

        # Should only include sales with revenue > 150
        total_high_revenue_count = constrained_results.sum { |group| group["count"] }
        assert total_high_revenue_count <= 7, "Should have fewer sales when constrained"
        assert total_high_revenue_count >= 3, "Should have some high-revenue sales"

        puts "✅ Group by date with constraints works correctly"
      end
    end
  end

  def test_combined_grouping_features
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(25, "combined grouping features test") do
        puts "\n=== Testing Combined Grouping Features ==="

        # Create comprehensive test data
        products = [
          { name: "Product A", category: "tech", price: 299.99, tags: ["gadget", "popular"], launch_date: Date.new(2023, 6, 15) },
          { name: "Product B", category: "tech", price: 199.99, tags: ["gadget", "budget"], launch_date: Date.new(2023, 7, 10) },
          { name: "Product C", category: "home", price: 89.99, tags: ["furniture", "popular"], launch_date: Date.new(2023, 8, 5) }
        ]

        products.each do |product_data|
          product = AggregationProduct.new(product_data)
          assert product.save, "Product #{product_data[:name]} should save"
        end

        # Test sortable grouping with flatten_arrays
        puts "Testing sortable grouping with flatten_arrays..."
        sortable_flattened = AggregationProduct.query.sortable_group_by(:tags, 
                                                                       flatten_arrays: true, 
                                                                       sortable: { price: -1 })
        combined_results = sortable_flattened.results

        assert combined_results.is_a?(Array), "Results should be an array"
        
        # Should have individual tags as groups
        tag_names = combined_results.map { |group| group["_id"] }
        expected_tags = ["gadget", "popular", "budget", "furniture"]
        expected_tags.each do |tag|
          assert_includes tag_names, tag, "Should have #{tag} as a group"
        end

        # Verify sorting within groups
        popular_group = combined_results.find { |group| group["_id"] == "popular" }
        if popular_group && popular_group["results"]
          prices = popular_group["results"].map { |p| p["price"] }
          assert_equal prices, prices.sort.reverse, "Products should be sorted by price descending"
        end

        puts "✅ Combined sortable grouping with flatten_arrays works correctly"

        # Test group_by_date with additional pipeline stages
        puts "Testing group_by_date with complex aggregation..."
        complex_date_group = AggregationProduct.query
                                             .where(:price.gt => 150)
                                             .group_by_date(:launch_date, :month, return_pointers: false)
        complex_results = complex_date_group.results

        assert complex_results.is_a?(Array), "Results should be an array"
        
        # All results should be from products with price > 150
        complex_results.each do |group|
          if group["results"]
            group["results"].each do |product|
              assert product["price"] > 150, "All products should meet price constraint"
            end
          end
        end

        puts "✅ Complex group_by_date aggregation works correctly"

        puts "✅ All combined grouping features work correctly"
      end
    end
  end
end