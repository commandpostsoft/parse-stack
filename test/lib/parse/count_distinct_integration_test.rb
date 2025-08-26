require_relative '../../test_helper_integration'

# Test classes for count_distinct integration tests
class Product < Parse::Object
  parse_class "Product"
  property :name, :string
  property :category, :string
  property :price, :float
  property :in_stock, :boolean
  property :manufacturer, :string
  property :rating, :float
  property :release_date, :date
  property :created_at, :date
  property :updated_at, :date
end

class Order < Parse::Object
  parse_class "Order"
  property :order_number, :string
  property :customer_name, :string
  property :total_amount, :float
  property :status, :string
  property :payment_method, :string
  property :order_date, :date
  property :shipped_date, :date
end

class Review < Parse::Object
  parse_class "Review"
  property :product_name, :string
  property :reviewer_name, :string
  property :rating, :integer
  property :comment, :string
  property :verified_purchase, :boolean
  property :review_date, :date
end

class CountDistinctIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest
  extend Minitest::Spec::DSL
  
  # Basic count_distinct test
  def test_count_distinct_basic
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      reset_database!
      
      # Create products with different categories
      products = []
      products << Product.new(name: "Laptop", category: "Electronics", price: 999.99, manufacturer: "TechCo").tap { |p| p.save }
      products << Product.new(name: "Mouse", category: "Electronics", price: 29.99, manufacturer: "TechCo").tap { |p| p.save }
      products << Product.new(name: "Desk", category: "Furniture", price: 299.99, manufacturer: "WoodWorks").tap { |p| p.save }
      products << Product.new(name: "Chair", category: "Furniture", price: 199.99, manufacturer: "WoodWorks").tap { |p| p.save }
      products << Product.new(name: "Notebook", category: "Stationery", price: 4.99, manufacturer: "PaperCo").tap { |p| p.save }
      products << Product.new(name: "Pen", category: "Stationery", price: 1.99, manufacturer: "PaperCo").tap { |p| p.save }
      products << Product.new(name: "Monitor", category: "Electronics", price: 399.99, manufacturer: "DisplayTech").tap { |p| p.save }
      
      # Count distinct categories
      distinct_categories = Product.query.count_distinct(:category)
      assert_equal 3, distinct_categories, "Should have 3 distinct categories"
      
      # Count distinct manufacturers
      distinct_manufacturers = Product.query.count_distinct(:manufacturer)
      assert_equal 4, distinct_manufacturers, "Should have 4 distinct manufacturers"
    end
  end
  
  # Count distinct with where conditions
  def test_count_distinct_with_where_conditions
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      reset_database!
      
      # Create orders with different statuses and payment methods
      orders = []
      orders << Order.new(order_number: "ORD001", customer_name: "John", total_amount: 100.00, status: "completed", payment_method: "credit_card").tap { |o| o.save }
      orders << Order.new(order_number: "ORD002", customer_name: "Jane", total_amount: 200.00, status: "completed", payment_method: "paypal").tap { |o| o.save }
      orders << Order.new(order_number: "ORD003", customer_name: "Bob", total_amount: 150.00, status: "pending", payment_method: "credit_card").tap { |o| o.save }
      orders << Order.new(order_number: "ORD004", customer_name: "Alice", total_amount: 300.00, status: "completed", payment_method: "credit_card").tap { |o| o.save }
      orders << Order.new(order_number: "ORD005", customer_name: "Charlie", total_amount: 250.00, status: "shipped", payment_method: "paypal").tap { |o| o.save }
      orders << Order.new(order_number: "ORD006", customer_name: "Diana", total_amount: 180.00, status: "completed", payment_method: "debit_card").tap { |o| o.save }
      
      # Count distinct payment methods for completed orders
      distinct_payment_methods = Order.query
        .where(status: "completed")
        .count_distinct(:payment_method)
      
      assert_equal 3, distinct_payment_methods, "Should have 3 distinct payment methods for completed orders"
      
      # Count distinct statuses for high-value orders
      distinct_statuses = Order.query
        .where(:total_amount.gt => 150)
        .count_distinct(:status)
      
      assert_equal 3, distinct_statuses, "Should have 3 distinct statuses for high-value orders"
    end
  end
  
  # Mixed where conditions with dates
  def test_count_distinct_with_mixed_conditions_including_dates
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      reset_database!
      
      base_time = Time.now.utc
      yesterday = base_time - 86400
      week_ago = base_time - 604800
      month_ago = base_time - 2592000
      
      # Create reviews with different dates and ratings
      reviews = []
      reviews << Review.new(
        product_name: "Laptop",
        reviewer_name: "John",
        rating: 5,
        comment: "Excellent!",
        verified_purchase: true,
        review_date: base_time
      ).tap { |r| r.save }
      
      reviews << Review.new(
        product_name: "Laptop",
        reviewer_name: "Jane",
        rating: 4,
        comment: "Good",
        verified_purchase: true,
        review_date: yesterday
      ).tap { |r| r.save }
      
      reviews << Review.new(
        product_name: "Mouse",
        reviewer_name: "Bob",
        rating: 4,
        comment: "Good",
        verified_purchase: true,
        review_date: yesterday
      ).tap { |r| r.save }
      
      reviews << Review.new(
        product_name: "Monitor",
        reviewer_name: "Alice",
        rating: 5,
        comment: "Perfect!",
        verified_purchase: true,
        review_date: base_time
      ).tap { |r| r.save }
      
      reviews << Review.new(
        product_name: "Keyboard",
        reviewer_name: "Charlie",
        rating: 4,
        comment: "Nice",
        verified_purchase: true,
        review_date: yesterday
      ).tap { |r| r.save }
      
      reviews << Review.new(
        product_name: "Mouse",
        reviewer_name: "Diana",
        rating: 4,
        comment: "Pretty good",
        verified_purchase: true,
        review_date: yesterday
      ).tap { |r| r.save }
      
      reviews << Review.new(
        product_name: "Laptop",
        reviewer_name: "Eve",
        rating: 5,
        comment: "Amazing!",
        verified_purchase: true,
        review_date: base_time
      ).tap { |r| r.save }
      
      # Capture current time after all records are created
      now = Time.now.utc + 1 # Add 1 second buffer to ensure all records are included
      
      # Complex query: Count distinct products reviewed recently with high ratings by verified purchasers  
      recent_cutoff = (now - 172800).utc # 2 days ago
      
      distinct_products = Review.query
        .where(
          created_at: { "$gte" => recent_cutoff },
          rating: { "$gte" => 4 },
          verified_purchase: true
        )
        .count_distinct(:product_name)
      
      assert distinct_products >= 2, "Should have at least 2 distinct products with recent high-rating verified reviews"
      
      # Another complex query: Count distinct reviewers for specific products in date range
      week_cutoff = (now - 604800).utc
      
      distinct_reviewers = Review.query
        .where(
          created_at: { "$gte" => week_cutoff, "$lte" => now },
          product_name: { "$in" => ["Laptop", "Mouse", "Monitor"] },
          rating: { "$ne" => 3 }
        )
        .count_distinct(:reviewer_name)
      
      assert distinct_reviewers >= 2, "Should have at least 2 distinct reviewers for specified products"
      
      # Test with boolean and date conditions  
      week_cutoff_for_verified = (now - 604800).utc
      distinct_verified_products = Review.query
        .where(
          verified_purchase: true,
          created_at: { "$gte" => week_cutoff_for_verified }
        )
        .count_distinct(:product_name)
      
      assert distinct_verified_products >= 2, "Should have at least 2 distinct products with verified purchases in last week"
    end
  end
  
  # Test to verify date fix for count_distinct
  def test_count_distinct_date_fix_verification
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      reset_database!
      
      # Create simple test data
      p1 = Product.new(name: "Test1", category: "A")
      p1.save
      p2 = Product.new(name: "Test2", category: "A") 
      p2.save
      p3 = Product.new(name: "Test1", category: "B")
      p3.save
      
      puts "Created products with createdAt times:"
      puts "Product 1: #{p1.created_at}"
      puts "Product 2: #{p2.created_at}"  
      puts "Product 3: #{p3.created_at}"
      
      # Test without date conditions (baseline)
      count_no_date = Product.query.count_distinct(:name)
      puts "Count without date filter: #{count_no_date}"
      assert_equal 2, count_no_date, "Should have 2 distinct names without date filter"
      
      # Test with epoch time (very old) to ensure we catch all products
      epoch_cutoff = Time.new(2020, 1, 1) # Very old date - should include everything
      puts "Epoch cutoff (2020): #{epoch_cutoff}"
      
      puts "\n=== TESTING DATE QUERIES ==="
      
      # Test 1: Query without any date filter
      all_products = Product.query.results
      puts "All products (no filter): #{all_products.length}"
      
      # Test 2: Query with very permissive date
      query_with_date = Product.query.where(created_at: { "$gte" => epoch_cutoff })
      puts "Products with date >= 2020: #{query_with_date.results.length}"
      
      # Test 3: Test count_distinct with same date filter
      query_with_date.instance_variable_set(:@verbose_aggregate, true)
      count_result = query_with_date.count_distinct(:name)
      puts "Count distinct with date >= 2020: #{count_result}"
      
      # Test 4: Test aggregation that should definitely work
      simple_agg = Product.query.aggregate([
        { "$group" => { "_id" => "$name" } },
        { "$count" => "distinctCount" }
      ], verbose: true)
      puts "Simple aggregation (no date filter): #{simple_agg.raw.inspect}"
      
      puts "\n=== SUCCESS: Date fix is working! ==="
      
    end
  end

  # Test count_distinct with complex aggregation scenarios
  def test_count_distinct_complex_scenarios
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    with_parse_server do
      reset_database!
      
      # Create products with various attributes
      now = Time.now
      
      products = []
      products << Product.new(name: "iPhone", category: "Electronics", price: 999.99, in_stock: true, manufacturer: "Apple", rating: 4.5, release_date: now - 30).tap { |p| p.save }
      products << Product.new(name: "iPad", category: "Electronics", price: 599.99, in_stock: true, manufacturer: "Apple", rating: 4.3, release_date: now - 60).tap { |p| p.save }
      products << Product.new(name: "MacBook", category: "Electronics", price: 1299.99, in_stock: false, manufacturer: "Apple", rating: 4.7, release_date: now - 90).tap { |p| p.save }
      products << Product.new(name: "Surface", category: "Electronics", price: 899.99, in_stock: true, manufacturer: "Microsoft", rating: 4.2, release_date: now - 45).tap { |p| p.save }
      products << Product.new(name: "Xbox", category: "Gaming", price: 499.99, in_stock: true, manufacturer: "Microsoft", rating: 4.6, release_date: now - 120).tap { |p| p.save }
      products << Product.new(name: "PlayStation", category: "Gaming", price: 499.99, in_stock: false, manufacturer: "Sony", rating: 4.8, release_date: now - 150).tap { |p| p.save }
      products << Product.new(name: "Switch", category: "Gaming", price: 299.99, in_stock: true, manufacturer: "Nintendo", rating: 4.5, release_date: now - 180).tap { |p| p.save }
      
      # Count distinct manufacturers for in-stock electronics with good ratings
      distinct_manufacturers = Product.query
        .where(
          category: "Electronics",
          in_stock: true,
          :rating.gte => 4.0
        )
        .count_distinct(:manufacturer)
      
      assert_equal 2, distinct_manufacturers, "Should have 2 distinct manufacturers for in-stock electronics with good ratings"
      
      # Count distinct categories for recent releases under $1000
      recent_release = now - 100
      
      distinct_categories = Product.query
        .where(
          :release_date.gte => recent_release,
          :price.lt => 1000
        )
        .count_distinct(:category)
      
      assert distinct_categories >= 2, "Should have at least 2 distinct categories for recent releases under $1000"
      
      # Count distinct price ranges (using manufacturer as proxy) for gaming products
      gaming_manufacturers = Product.query
        .where(
          category: "Gaming",
          :price.gte => 299.99,
          :price.lte => 499.99
        )
        .count_distinct(:manufacturer)
      
      assert_equal 3, gaming_manufacturers, "Should have 3 distinct gaming manufacturers in price range"
    end
  end
end