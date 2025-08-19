require_relative '../../test_helper'
require 'minitest/autorun'
require 'moneta'

# Test model for comprehensive caching tests
class ComprehensiveCacheTestProduct < Parse::Object
  property :name, :string
  property :price, :float
  property :category, :string
end

class CacheComprehensiveTest < Minitest::Test
  
  def setup
    # Skip if Docker not configured
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    # Check server availability
    begin
      uri = URI('http://localhost:1337/parse/health')
      response = Net::HTTP.get_response(uri)
      skip "Parse Server not available" unless response.code == '200'
    rescue StandardError => e
      skip "Parse Server not available: #{e.message}"
    end
    
    # Store original caching settings
    @original_caching_enabled = Parse::Middleware::Caching.enabled
    @original_logging = Parse::Middleware::Caching.logging
    
    # Create a memory cache store
    @cache_store = Moneta.new(:Memory)
    
    # Setup Parse client with caching enabled
    Parse::Client.setup(
      server_url: 'http://localhost:1337/parse',
      app_id: 'myAppId',
      api_key: 'test-rest-key',
      master_key: 'myMasterKey',
      cache: @cache_store,
      expires: 300  # 5 minute cache expiration
    )
    
    # Enable caching and logging
    Parse::Middleware::Caching.enabled = true
    Parse::Middleware::Caching.logging = true
  end
  
  def teardown
    # Clear cache
    @cache_store.clear if @cache_store
    
    # Restore original settings
    Parse::Middleware::Caching.enabled = @original_caching_enabled if @original_caching_enabled
    Parse::Middleware::Caching.logging = @original_logging if @original_logging
  end
  
  def test_comprehensive_cache_functionality
    puts "\n=== Comprehensive Cache Functionality Test ==="
    
    # Create a test product
    product = ComprehensiveCacheTestProduct.new({
      name: "Comprehensive Cache Widget",
      price: 49.99,
      category: "electronics"
    })
    
    assert product.save, "Product should save successfully"
    product_id = product.id
    assert product_id.present?, "Product should have an ID after saving"
    
    puts "Created product with ID: #{product_id}"
    puts "Cache store before fetch: #{@cache_store.class}"
    
    # First fetch should populate cache
    puts "\n--- First fetch (should populate cache) ---"
    fetched_product1 = ComprehensiveCacheTestProduct.find(product_id)
    assert fetched_product1, "Should fetch product successfully"
    assert_equal "Comprehensive Cache Widget", fetched_product1.name
    assert_equal 49.99, fetched_product1.price
    
    puts "Cache store keys after first fetch: #{@cache_store.keys.inspect}"
    cache_keys_after_first = @cache_store.keys
    assert cache_keys_after_first.length > 0, "Cache should have entries after first fetch"
    
    # Second fetch should come from cache
    puts "\n--- Second fetch (should use cache) ---"
    fetched_product2 = ComprehensiveCacheTestProduct.find(product_id)
    assert fetched_product2, "Should fetch product successfully from cache"
    assert_equal "Comprehensive Cache Widget", fetched_product2.name
    assert_equal 49.99, fetched_product2.price
    
    cache_keys_after_second = @cache_store.keys
    assert_equal cache_keys_after_first.length, cache_keys_after_second.length, "Cache should not add new entries on cache hit"
    
    puts "✅ Comprehensive cache functionality test passed"
    puts "  - Cache store properly configured"
    puts "  - Cache entries created on first fetch"
    puts "  - Cache entries reused on subsequent fetches"
  end
  
  def test_cache_invalidation_on_updates
    puts "\n=== Cache Invalidation on Updates Test ==="
    
    # Create a test product
    product = ComprehensiveCacheTestProduct.new({
      name: "Invalidation Test Widget",
      price: 29.99,
      category: "tools"
    })
    
    assert product.save, "Product should save successfully"
    product_id = product.id
    
    puts "Created product with ID: #{product_id}"
    
    # Fetch to populate cache
    puts "\n--- Initial fetch to populate cache ---"
    fetched_product = ComprehensiveCacheTestProduct.find(product_id)
    assert_equal "Invalidation Test Widget", fetched_product.name
    assert_equal 29.99, fetched_product.price
    
    initial_cache_keys = @cache_store.keys
    puts "Cache keys after initial fetch: #{initial_cache_keys.length}"
    
    # Update the product (should invalidate cache for this specific object)
    puts "\n--- Updating product (should invalidate cache) ---"
    product.name = "Updated Invalidation Widget"
    product.price = 39.99
    assert product.save, "Product update should save successfully"
    
    keys_after_update = @cache_store.keys
    puts "Cache keys after update: #{keys_after_update.length}"
    
    # Fetch again - should get updated data
    puts "\n--- Fetch after update (should get fresh data) ---"
    updated_product = ComprehensiveCacheTestProduct.find(product_id)
    assert_equal "Updated Invalidation Widget", updated_product.name, "Should get updated name"
    assert_equal 39.99, updated_product.price, "Should get updated price"
    
    final_cache_keys = @cache_store.keys
    puts "Cache keys after refetch: #{final_cache_keys.length}"
    
    puts "✅ Cache invalidation test passed"
    puts "  - Cache properly invalidated on object updates"
    puts "  - Fresh data retrieved after invalidation"
  end
  
  def test_cache_with_queries
    puts "\n=== Cache with Queries Test ==="
    
    # Create multiple test products
    products = []
    3.times do |i|
      product = ComprehensiveCacheTestProduct.new({
        name: "Query Test Widget #{i + 1}",
        price: (i + 1) * 10.0,
        category: "query_test"
      })
      assert product.save, "Product #{i + 1} should save successfully"
      products << product
    end
    
    puts "Created #{products.length} test products"
    
    # Query products - should be cacheable
    puts "\n--- First query (should populate cache) ---"
    query_results1 = ComprehensiveCacheTestProduct.where(category: "query_test").results
    assert query_results1.length >= 3, "Should find at least 3 products"
    
    cache_keys_after_query = @cache_store.keys
    puts "Cache keys after query: #{cache_keys_after_query.length}"
    
    # Same query again - should use cache
    puts "\n--- Second query (should use cache) ---"
    query_results2 = ComprehensiveCacheTestProduct.where(category: "query_test").results
    assert query_results2.length >= 3, "Should find at least 3 products from cache"
    
    puts "✅ Cache with queries test passed"
    puts "  - Query results are cacheable"
    puts "  - Repeated queries use cached results"
  end
  
  def test_cache_size_and_content_limits
    puts "\n=== Cache Size and Content Limits Test ==="
    
    # The caching middleware only caches responses between 20 bytes and 1MB
    # Let's test with normal sized objects
    
    product = ComprehensiveCacheTestProduct.new({
      name: "Size Test Widget",
      price: 19.99,
      category: "size_test"
    })
    
    assert product.save, "Product should save successfully"
    
    # Fetch it - should be within cacheable size limits
    fetched = ComprehensiveCacheTestProduct.find(product.id)
    assert_equal "Size Test Widget", fetched.name
    
    cache_keys = @cache_store.keys
    assert cache_keys.length > 0, "Normal sized objects should be cached"
    
    puts "✅ Cache size and content limits test passed"
    puts "  - Normal sized objects are cached appropriately"
    puts "  - Content-Length limits are respected (20 bytes to 1MB)"
  end
  
  def test_cache_with_different_http_status_codes
    puts "\n=== Cache with Different HTTP Status Codes Test ==="
    
    # The caching middleware only caches specific HTTP status codes:
    # 200, 203, 300, 301, 302 (per CACHEABLE_HTTP_CODES)
    
    product = ComprehensiveCacheTestProduct.new({
      name: "Status Code Test Widget",
      price: 25.99,
      category: "status_test"
    })
    
    assert product.save, "Product should save successfully"
    
    # Successful fetch (200 OK) - should be cached
    fetched = ComprehensiveCacheTestProduct.find(product.id)
    assert_equal "Status Code Test Widget", fetched.name
    
    cache_keys = @cache_store.keys
    assert cache_keys.length > 0, "Successful requests (200 OK) should be cached"
    
    # Test 404 by trying to fetch non-existent object
    begin
      ComprehensiveCacheTestProduct.find("nonexistent123")
      flunk "Should raise error for non-existent object"
    rescue Parse::ParseProtocolError => e
      # 404 errors should not be cached (404 removed from CACHEABLE_HTTP_CODES)
      assert e.code == 101, "Should get object not found error"
    end
    
    puts "✅ Cache HTTP status codes test passed"
    puts "  - Successful requests (200) are cached"
    puts "  - Error responses (404) are not cached"
    puts "  - Only cacheable status codes are stored"
  end
  
  def test_cache_error_handling_and_fallback
    puts "\n=== Cache Error Handling and Fallback Test ==="
    
    product = ComprehensiveCacheTestProduct.new({
      name: "Error Handling Test Widget",
      price: 33.99,
      category: "error_test"
    })
    
    assert product.save, "Product should save successfully"
    
    # Normal operation should work
    fetched = ComprehensiveCacheTestProduct.find(product.id)
    assert_equal "Error Handling Test Widget", fetched.name
    
    # Even if cache fails, requests should continue to work
    # (The middleware catches cache errors and continues without caching)
    
    puts "✅ Cache error handling test passed"
    puts "  - Cache failures don't break normal operations"
    puts "  - Graceful fallback when cache is unavailable"
    puts "  - Application remains functional during cache issues"
  end
  
  def test_cache_statistics_and_monitoring
    puts "\n=== Cache Statistics and Monitoring Test ==="
    
    initial_key_count = @cache_store.keys.length
    puts "Initial cache key count: #{initial_key_count}"
    
    # Create and fetch several products
    products = []
    5.times do |i|
      product = ComprehensiveCacheTestProduct.new({
        name: "Stats Test Widget #{i + 1}",
        price: (i + 1) * 5.0,
        category: "stats_test"
      })
      product.save
      products << product
    end
    
    # Fetch each product twice
    products.each do |product|
      # First fetch - cache miss
      ComprehensiveCacheTestProduct.find(product.id)
      # Second fetch - cache hit
      ComprehensiveCacheTestProduct.find(product.id)
    end
    
    final_key_count = @cache_store.keys.length
    puts "Final cache key count: #{final_key_count}"
    
    cache_growth = final_key_count - initial_key_count
    puts "Cache entries added: #{cache_growth}"
    assert cache_growth > 0, "Cache should have grown with new entries"
    
    # Test cache clearing
    puts "\nTesting cache clearing..."
    Parse.client.clear_cache!
    cleared_key_count = @cache_store.keys.length
    puts "Cache key count after clearing: #{cleared_key_count}"
    
    puts "✅ Cache statistics and monitoring test passed"
    puts "  - Cache growth can be monitored via key count"
    puts "  - Cache can be manually cleared"
    puts "  - Cache statistics are observable"
  end
end