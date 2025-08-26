require_relative '../../test_helper'
require 'minitest/autorun'

# Test model for query cloning tests
class CloneTestProduct < Parse::Object
  parse_class "CloneTestProduct"
  
  property :name, :string
  property :category, :string
  property :price, :float
  property :tags, :array
  property :active, :boolean
  property :created_date, :date
  property :metadata, :object
end

class CloneTestUser < Parse::Object
  parse_class "CloneTestUser"
  
  property :username, :string
  property :email, :string
  property :age, :integer
end

class QueryCloneTest < Minitest::Test
  
  def test_clone_creates_independent_query_objects
    puts "\n=== Testing Clone Creates Independent Query Objects ==="
    
    # Create original query
    original = CloneTestProduct.where(:name => "Test Product")
    cloned = original.clone
    
    # Verify they are different objects
    refute_same original, cloned, "Cloned query should be a different object"
    assert_equal original.table, cloned.table, "Cloned query should have same table"
    
    # Modify cloned query and ensure original is unchanged
    cloned.where(:category => "Electronics")
    
    # Original should still have only the name constraint
    original_constraints = original.where.map(&:operand)
    cloned_constraints = cloned.where.map(&:operand)
    
    assert_equal [:name], original_constraints, "Original should only have name constraint"
    assert_equal [:name, :category], cloned_constraints, "Cloned should have both constraints"
    
    puts "✓ Clone creates independent query objects"
  end
  
  def test_clone_preserves_where_constraints
    puts "\n=== Testing Clone Preserves Where Constraints ==="
    
    # Create query with multiple constraints
    original = CloneTestProduct.where(
      :name => "Test Product",
      :price.gt => 10.0,
      :active => true,
      :tags.in => ["electronics", "gadgets"]
    )
    
    cloned = original.clone
    
    # Verify constraints are preserved
    original_operands = original.where.map(&:operand).sort
    cloned_operands = cloned.where.map(&:operand).sort
    
    assert_equal original_operands, cloned_operands, "Cloned query should preserve all constraint operands"
    
    # Verify constraint values are preserved
    original_name_constraint = original.where.find { |c| c.operand == :name }
    cloned_name_constraint = cloned.where.find { |c| c.operand == :name }
    
    assert_equal original_name_constraint.value, cloned_name_constraint.value, "Constraint values should be preserved"
    
    # Verify complex constraint values
    original_tags_constraint = original.where.find { |c| c.operand == :tags }
    cloned_tags_constraint = cloned.where.find { |c| c.operand == :tags }
    
    assert_equal original_tags_constraint.value, cloned_tags_constraint.value, "Array constraint values should be preserved"
    
    puts "✓ Clone preserves where constraints correctly"
  end
  
  def test_clone_preserves_order_constraints
    puts "\n=== Testing Clone Preserves Order Constraints ==="
    
    # Create query with ordering
    original = CloneTestProduct.where(:active => true)
                              .order(:name.asc, :price.desc, :created_date.asc)
    
    cloned = original.clone
    
    # Verify order is preserved
    assert_equal original.order.length, cloned.order.length, "Should preserve all order constraints"
    
    original.order.each_with_index do |order_obj, index|
      cloned_order_obj = cloned.order[index]
      assert_equal order_obj.field, cloned_order_obj.field, "Order field should be preserved"
      assert_equal order_obj.direction, cloned_order_obj.direction, "Order direction should be preserved"
    end
    
    puts "✓ Clone preserves order constraints correctly"
  end
  
  def test_clone_preserves_limit_and_skip
    puts "\n=== Testing Clone Preserves Limit and Skip ==="
    
    # Create query with limit and skip
    original = CloneTestProduct.where(:active => true)
                              .limit(50)
                              .skip(100)
    
    cloned = original.clone
    
    assert_equal original.limit, cloned.limit, "Limit should be preserved"
    assert_equal original.skip, cloned.skip, "Skip should be preserved"
    
    puts "✓ Clone preserves limit and skip correctly"
  end
  
  def test_clone_preserves_keys_and_includes
    puts "\n=== Testing Clone Preserves Keys and Includes ==="
    
    # Create query with keys and includes
    original = CloneTestProduct.where(:active => true)
                              .keys(:name, :price, :category)
                              .includes(:author, :reviews)
    
    cloned = original.clone
    
    assert_equal original.keys.sort, cloned.keys.sort, "Keys should be preserved"
    assert_equal original.includes.sort, cloned.includes.sort, "Includes should be preserved"
    
    puts "✓ Clone preserves keys and includes correctly"
  end
  
  def test_clone_preserves_cache_and_master_key_settings
    puts "\n=== Testing Clone Preserves Cache and Master Key Settings ==="
    
    # Create query with cache and master key settings
    original = CloneTestProduct.where(:active => true)
    original.instance_variable_set(:@cache, false)
    original.instance_variable_set(:@use_master_key, true)
    
    cloned = original.clone
    
    assert_equal original.instance_variable_get(:@cache), cloned.instance_variable_get(:@cache), "Cache setting should be preserved"
    assert_equal original.instance_variable_get(:@use_master_key), cloned.instance_variable_get(:@use_master_key), "Master key setting should be preserved"
    
    puts "✓ Clone preserves cache and master key settings correctly"
  end
  
  def test_clone_resets_results_cache
    puts "\n=== Testing Clone Resets Results Cache ==="
    
    original = CloneTestProduct.where(:active => true)
    # Simulate cached results
    original.instance_variable_set(:@results, ["cached", "results"])
    
    cloned = original.clone
    
    assert_nil cloned.instance_variable_get(:@results), "Cloned query should not have cached results"
    assert_equal ["cached", "results"], original.instance_variable_get(:@results), "Original should keep its results"
    
    puts "✓ Clone correctly resets results cache"
  end
  
  def test_clone_handles_empty_query
    puts "\n=== Testing Clone Handles Empty Query ==="
    
    # Create empty query
    original = CloneTestProduct.query
    cloned = original.clone
    
    assert_equal original.table, cloned.table, "Empty query clone should preserve table"
    assert_equal 0, cloned.where.length, "Empty query clone should have no constraints"
    
    puts "✓ Clone handles empty query correctly"
  end
  
  def test_clone_handles_complex_nested_constraints
    puts "\n=== Testing Clone Handles Complex Nested Constraints ==="
    
    # Create query with complex constraints (OR conditions)
    original = CloneTestProduct.where(:active => true)
    original.or_where(:price.lt => 20)
    original.or_where(:category => "clearance")
    
    cloned = original.clone
    
    # Verify all constraints are preserved including OR conditions
    assert_equal original.where.length, cloned.where.length, "Should preserve all constraints including OR conditions"
    
    # Test that constraints work independently after cloning
    cloned.where(:name => "Additional Constraint")
    
    # Original shouldn't have the additional constraint
    original_operands = original.where.map(&:operand)
    cloned_operands = cloned.where.map(&:operand)
    
    refute cloned_operands == original_operands, "Queries should be independent after additional constraints"
    
    puts "✓ Clone handles complex nested constraints correctly"
  end
  
  def test_clone_with_pointer_constraints
    puts "\n=== Testing Clone with Pointer Constraints ==="
    
    # Create a user to use as pointer constraint
    user = CloneTestUser.new(username: "testuser", email: "test@example.com")
    
    # Create query with pointer constraint
    original = CloneTestProduct.where(:author => user, :active => true)
    cloned = original.clone
    
    # Find the pointer constraint
    original_author_constraint = original.where.find { |c| c.operand == :author }
    cloned_author_constraint = cloned.where.find { |c| c.operand == :author }
    
    assert_equal original_author_constraint.value, cloned_author_constraint.value, "Pointer constraint values should be preserved"
    
    puts "✓ Clone handles pointer constraints correctly"
  end
  
  def test_clone_with_date_constraints
    puts "\n=== Testing Clone with Date Constraints ==="
    
    test_date = Date.new(2023, 6, 15)
    
    # Create query with date constraints
    original = CloneTestProduct.where(
      :created_date.gte => test_date,
      :created_date.lt => test_date + 30
    )
    
    cloned = original.clone
    
    # Verify date constraints are preserved
    original_date_constraints = original.where.select { |c| c.operand == :created_date }
    cloned_date_constraints = cloned.where.select { |c| c.operand == :created_date }
    
    assert_equal original_date_constraints.length, cloned_date_constraints.length, "Should preserve all date constraints"
    
    original_date_constraints.each_with_index do |orig_constraint, index|
      cloned_constraint = cloned_date_constraints[index]
      assert_equal orig_constraint.value, cloned_constraint.value, "Date constraint values should be preserved"
    end
    
    puts "✓ Clone handles date constraints correctly"
  end
  
  def test_clone_with_array_and_object_constraints
    puts "\n=== Testing Clone with Array and Object Constraints ==="
    
    metadata_filter = { "featured" => true, "priority" => 1 }
    
    # Create query with array and object constraints
    original = CloneTestProduct.where(
      :tags.all => ["electronics", "featured"],
      :metadata => metadata_filter
    )
    
    cloned = original.clone
    
    # Verify array constraint
    original_tags_constraint = original.where.find { |c| c.operand == :tags }
    cloned_tags_constraint = cloned.where.find { |c| c.operand == :tags }
    
    assert_equal original_tags_constraint.value, cloned_tags_constraint.value, "Array constraint values should be preserved"
    
    # Verify object constraint
    original_metadata_constraint = original.where.find { |c| c.operand == :metadata }
    cloned_metadata_constraint = cloned.where.find { |c| c.operand == :metadata }
    
    assert_equal original_metadata_constraint.value, cloned_metadata_constraint.value, "Object constraint values should be preserved"
    
    puts "✓ Clone handles array and object constraints correctly"
  end
  
  def test_clone_independence_after_modifications
    puts "\n=== Testing Clone Independence After Modifications ==="
    
    # Create base query
    base = CloneTestProduct.where(:active => true, :price.gt => 10)
    
    # Create multiple clones
    clone1 = base.clone
    clone2 = base.clone
    
    # Modify each query differently
    clone1.where(:category => "Electronics").order(:name.asc)
    clone2.where(:category => "Books").order(:price.desc).limit(20)
    
    # Verify base query is unchanged
    base_operands = base.where.map(&:operand).sort
    assert_equal [:active, :price], base_operands, "Base query should be unchanged"
    assert_equal 0, base.order.length, "Base query should have no ordering"
    assert_nil base.limit, "Base query should have no limit"
    
    # Verify clones are independent
    clone1_operands = clone1.where.map(&:operand).sort
    clone2_operands = clone2.where.map(&:operand).sort
    
    assert_equal [:active, :category, :price], clone1_operands, "Clone1 should have its own constraints"
    assert_equal [:active, :category, :price], clone2_operands, "Clone2 should have its own constraints"
    
    # But different category values
    clone1_category = clone1.where.find { |c| c.operand == :category }.value
    clone2_category = clone2.where.find { |c| c.operand == :category }.value
    
    assert_equal "Electronics", clone1_category, "Clone1 should have Electronics category"
    assert_equal "Books", clone2_category, "Clone2 should have Books category"
    
    puts "✓ Clone independence works correctly after modifications"
  end
  
  def test_clone_marshal_fallback_handling
    puts "\n=== Testing Clone Marshal Fallback Handling ==="
    
    # Create a query
    original = CloneTestProduct.where(:name => "Test")
    
    # Mock Marshal to fail and test fallback
    original_marshal_dump = Marshal.method(:dump)
    Marshal.define_singleton_method(:dump) do |obj|
      raise "Simulated Marshal failure"
    end
    
    begin
      # Capture output to verify fallback message
      output = capture_output do
        cloned = original.clone
        
        # Should still work with fallback
        assert_equal original.table, cloned.table, "Fallback should still work"
        assert_equal original.where.length, cloned.where.length, "Fallback should preserve constraints"
      end
      
      assert_match(/Marshal failed.*falling back to dup/, output, "Should show fallback message")
      
    ensure
      # Restore original Marshal.dump
      Marshal.define_singleton_method(:dump, original_marshal_dump)
    end
    
    puts "✓ Clone handles Marshal fallback correctly"
  end
  
  def test_clone_performance_with_complex_queries
    puts "\n=== Testing Clone Performance with Complex Queries ==="
    
    # Create a complex query
    complex_query = CloneTestProduct.where(:active => true)
                                   .where(:price.between => [10, 100])
                                   .where(:tags.in => ["electronics", "gadgets", "accessories"])
                                   .where(:category.ne => "discontinued")
                                   .order(:name.asc, :price.desc)
                                   .keys(:name, :price, :category, :tags)
                                   .includes(:author, :reviews, :ratings)
                                   .limit(50)
                                   .skip(25)
    
    # Test cloning performance
    start_time = Time.now
    cloned = complex_query.clone
    clone_time = Time.now - start_time
    
    # Verify clone worked correctly
    assert_equal complex_query.where.length, cloned.where.length, "Complex query constraints should be preserved"
    assert_equal complex_query.order.length, cloned.order.length, "Complex query ordering should be preserved"
    assert_equal complex_query.keys, cloned.keys, "Complex query keys should be preserved"
    assert_equal complex_query.includes, cloned.includes, "Complex query includes should be preserved"
    assert_equal complex_query.limit, cloned.limit, "Complex query limit should be preserved"
    assert_equal complex_query.skip, cloned.skip, "Complex query skip should be preserved"
    
    # Performance should be reasonable (less than 100ms for complex query)
    assert clone_time < 0.1, "Complex query cloning should be performant (took #{clone_time}s)"
    
    puts "✓ Clone performs well with complex queries (#{(clone_time * 1000).round(2)}ms)"
  end
  
  private
  
  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end
end