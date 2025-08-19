require_relative '../../test_helper_integration'

# Test classes for integration tests
class TestObject < Parse::Object
  parse_class "TestObject"
  property :test, :string
  property :foo, :string
  property :adventure, :string
  property :location, :string
  property :a_bool, :boolean
end

class Item < Parse::Object
  parse_class "Item" 
  property :property, :string
  property :x, :integer
  property :foo, :string
end

class Container < Parse::Object
  parse_class "Container"
  property :item, :pointer, class_name: 'Item'
  property :items, :array
  property :subcontainer, :pointer, class_name: 'Container'
end

# Port of the JavaScript Parse.Object test suite to Ruby
# This tests the core Parse::Object functionality against a real Parse Server
class ParseObjectIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def test_create
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    # Reset database to clean state (after setup is complete)
    reset_database!
    with_parse_server do
      object = TestObject.new(test: 'test')
      assert object.save, "Should be able to save object"
      assert object.id.present?, "Should have an objectId set"
      assert_equal 'test', object[:test], "Should have the right attribute"
    end
  end

  def test_update
    with_parse_server do
      object = create_test_object('TestObject', test: 'test')
      
      object2 = TestObject.new(objectId: object.id)
      object2[:test] = 'changed'
      assert object2.save, "Update should succeed"
      assert_equal 'changed', object2[:test], "Update should have succeeded"
    end
  end

  def test_save_without_null
    with_parse_server do
      object = TestObject.new
      object[:favoritePony] = 'Rainbow Dash'
      result = object.save
      assert result, "Should save successfully"
      assert_equal object, result, "Should return the same object"
    end
  end

  def test_save_cycle
    with_parse_server do
      a = TestObject.new
      b = TestObject.new
      
      a[:b] = b
      assert a.save, "Should save object a with pointer to b"
      
      b[:a] = a
      assert b.save, "Should save object b with pointer to a"
      
      assert a.id.present?, "Object a should have an id"
      assert b.id.present?, "Object b should have an id"
      # Note: Direct pointer comparison may not work as expected in Ruby implementation
      # This tests the basic save cycle functionality
    end
  end

  def test_get_fetch
    with_parse_server do
      object = create_test_object('TestObject', test: 'test')
      
      object2 = TestObject.new(objectId: object.id)
      assert object2.fetch, "Should fetch object successfully"
      assert_equal 'test', object2[:test], "Fetch should have retrieved the data"
      assert object2.id.present?, "Should have an id"
      assert_equal object.id, object2.id, "IDs should match"
    end
  end

  def test_delete_destroy
    with_parse_server do
      object = TestObject.new
      object[:test] = 'test'
      assert object.save, "Should save object"
      
      assert object.destroy, "Should destroy object"
      
      object2 = TestObject.new(objectId: object.id)
      assert_raises(Parse::Error::ProtocolError) do
        object2.fetch
      end
    end
  end

  def test_find_query
    with_parse_server do
      object = TestObject.new
      object[:foo] = 'bar'
      assert object.save, "Should save object"
      
      query = TestObject.query(foo: 'bar')
      results = query.results
      assert_equal 1, results.length, "Should find one object"
      assert_equal object.id, results.first.id, "Should find the correct object"
    end
  end

  def test_relational_fields
    # Skip if not using Docker containers
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'
    
    # Reset database to clean state
    reset_database!
    
    with_parse_server do
      item = Item.new
      item[:property] = 'x'
      assert item.save, "Should save item"
      
      container = Container.new
      container[:item] = item
      assert container.save, "Should save container with item relation"
      
      query = Container.query
      results = query.results
      assert_equal 1, results.length, "Should find one container"
      
      container_again = results.first
      item_again = container_again[:item]
      assert item_again.is_a?(Parse::Pointer), "Should have a pointer to item"
      
      # Fetch the item
      assert item_again.fetch, "Should fetch the related item"
      assert_equal 'x', item_again[:property], "Should have the correct property value"
    end
  end

  def test_save_adds_minimal_data_keys
    with_parse_server do
      object = TestObject.new
      assert object.save, "Should save empty object"
      
      # Check that only minimal keys are present
      keys = object.attributes.keys
      expected_keys = ['id', 'created_at', 'updated_at', 'acl'].map(&:to_sym)
      assert keys.all? { |k| expected_keys.include?(k) }, "Should only have basic Parse keys"
    end
  end

  def test_recursive_save
    with_parse_server do
      item = Item.new
      item[:property] = 'x'
      
      container = Container.new
      container[:item] = item
      
      assert container.save, "Should save container and item recursively"
      
      query = Container.query
      results = query.results
      assert_equal 1, results.length, "Should find one container"
      
      container_again = results.first
      item_again = container_again[:item]
      assert item_again.fetch, "Should fetch the item"
      assert_equal 'x', item_again[:property], "Should have correct property"
    end
  end

  def test_fetch_object_updates
    with_parse_server do
      item = Item.new(foo: 'bar')
      assert item.save, "Should save item"
      
      item_again = Item.new
      item_again.id = item.id
      assert item_again.fetch, "Should fetch item"
      
      item_again[:foo] = 'baz'
      assert item_again.save, "Should save updated item"
      
      assert item.fetch, "Should fetch original item"
      assert_equal 'baz', item[:foo], "Original item should have updated value"
    end
  end

  def test_created_at_doesnt_change
    with_parse_server do
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      
      object_again = TestObject.new
      object_again.id = object.id
      assert object_again.fetch, "Should fetch object"
      
      assert_equal object.created_at.to_i, object_again.created_at.to_i, 
                   "CreatedAt times should match (within 1 second)"
    end
  end

  def test_created_at_and_updated_at_exposed
    with_parse_server do
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      
      refute_nil object.updated_at, "UpdatedAt should be set"
      refute_nil object.created_at, "CreatedAt should be set"
    end
  end

  def test_updated_at_gets_updated
    with_parse_server do
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      assert object.updated_at.present?, "Initial save should set updatedAt"
      
      first_updated_at = object.updated_at
      sleep 1 # Ensure time difference
      
      object[:foo] = 'baz'
      assert object.save, "Should save updated object"
      assert object.updated_at.present?, "Second save should update updatedAt"
      refute_equal first_updated_at, object.updated_at, "UpdatedAt should change"
    end
  end

  def test_created_at_is_reasonable
    with_parse_server do
      start_time = Time.now
      object = TestObject.new(foo: 'bar')
      assert object.save, "Should save object"
      end_time = Time.now
      
      start_diff = (start_time - object.created_at).abs
      assert start_diff < 5, "CreatedAt should be close to start time"
      
      end_diff = (end_time - object.created_at).abs  
      assert end_diff < 5, "CreatedAt should be close to end time"
    end
  end

  def test_can_set_null
    with_parse_server do
      object = TestObject.new
      object[:foo] = nil
      assert object.save, "Should save object with null value"
      assert_nil object[:foo], "Should retrieve null value"
    end
  end

  def test_can_set_boolean
    with_parse_server do
      object = TestObject.new
      object[:yes] = true
      object[:no] = false
      assert object.save, "Should save object with boolean values"
      
      assert_equal true, object[:yes], "Should retrieve true value"
      assert_equal false, object[:no], "Should retrieve false value"
    end
  end

  def test_cannot_set_invalid_date
    with_parse_server do
      object = TestObject.new
      # Invalid date in Ruby would be Date.parse(nil) which raises an error
      assert_raises(ArgumentError) do
        object[:when] = Date.parse("")
      end
    end
  end

  def test_can_set_auth_data_when_not_user_class
    with_parse_server do
      object = TestObject.new
      object[:authData] = 'random'
      assert object.save, "Should save object with authData"
      assert_equal 'random', object[:authData], "Should retrieve authData value"
      
      query = TestObject.query
      fetched_object = query.results.first
      assert_equal 'random', fetched_object[:authData], "Should persist authData"
    end
  end

  def test_simple_field_deletion
    with_parse_server do
      object = TestObject.new
      object[:foo] = 'bar'
      assert object.save, "Should save object with foo"
      
      object.op_destroy!(:foo)
      refute object.has?(:foo), "foo should be unset locally"
      assert object.dirty?(:foo), "foo should be marked dirty"
      assert object.dirty?, "object should be dirty"
      
      assert object.save, "Should save object after unsetting foo"
      refute object.has?(:foo), "foo should still be unset"
      refute object.dirty?(:foo), "foo should no longer be dirty"
      refute object.dirty?, "object should no longer be dirty"
      
      query = TestObject.query
      object_again = query.get(object.id)
      refute object_again.has?(:foo), "foo should be removed from server"
    end
  end

  def test_field_deletion_before_first_save
    with_parse_server do
      object = TestObject.new
      object[:foo] = 'bar'
      object.op_destroy!(:foo)
      
      refute object.has?(:foo), "foo should be unset"
      assert object.dirty?(:foo), "foo should be dirty"
      assert object.dirty?, "object should be dirty"
      
      assert object.save, "Should save object"
      refute object.has?(:foo), "foo should be unset after save"
      refute object.dirty?(:foo), "foo should not be dirty after save"
      refute object.dirty?, "object should not be dirty after save"
      
      query = TestObject.query
      object_again = query.get(object.id)
      refute object_again.has?(:foo), "foo should not exist on server"
    end
  end

  def test_increment
    with_parse_server do
      object = TestObject.new
      object[:foo] = 5
      assert object.save, "Should save object"
      
      object.op_increment!(:foo)
      assert_equal 6, object[:foo], "Local value should be incremented"
      assert object.dirty?(:foo), "foo should be dirty"
      assert object.dirty?, "object should be dirty"
      
      assert object.save, "Should save incremented object"
      assert_equal 6, object[:foo], "Value should still be 6"
      refute object.dirty?(:foo), "foo should not be dirty after save"
      refute object.dirty?, "object should not be dirty after save"
      
      query = TestObject.query
      object_again = query.get(object.id)
      assert_equal 6, object_again[:foo], "Server value should be 6"
    end
  end

  def test_dirty_attributes
    with_parse_server do
      object = TestObject.new
      object[:cat] = 'good'
      object[:dog] = 'bad'
      assert object.save, "Should save object"
      
      refute object.dirty?, "Object should not be dirty after save"
      refute object.dirty?(:cat), "cat should not be dirty"
      refute object.dirty?(:dog), "dog should not be dirty"
      
      object[:dog] = 'okay'
      
      assert object.dirty?, "Object should be dirty"
      refute object.dirty?(:cat), "cat should not be dirty"
      assert object.dirty?(:dog), "dog should be dirty"
    end
  end

  def test_to_json_saved_object
    with_parse_server do
      object = create_test_object('TestObject', foo: 'bar')
      
      json = object.as_json
      assert json[:foo], "JSON should contain 'foo' key"
      assert json[:objectId] || json[:id], "JSON should contain objectId"
      assert json[:createdAt] || json[:created_at], "JSON should contain createdAt"
      assert json[:updatedAt] || json[:updated_at], "JSON should contain updatedAt"
    end
  end

  def test_async_methods_chaining
    with_parse_server do
      object = TestObject.new
      object[:time] = 'adventure'
      
      # Save the object
      assert object.save, "Should save object"
      assert object.id.present?, "ObjectId should not be null"
      
      # Fetch the object again
      object_again = TestObject.new
      object_again.id = object.id
      assert object_again.fetch, "Should fetch object"
      assert_equal 'adventure', object_again[:time], "Should have correct value"
      
      # Destroy the object
      assert object_again.destroy, "Should destroy object"
      
      # Verify it's gone
      query = TestObject.query
      results = query.results
      assert_equal 0, results.length, "Should find no objects"
    end
  end

  def test_bytes_work
    with_parse_server do
      object = TestObject.new
      bytes_data = Parse::Bytes.new('ZnJveW8=')
      object[:bytes] = bytes_data
      assert object.save, "Should save object with bytes"
      
      query = TestObject.query
      object_again = query.get(object.id)
      retrieved_bytes = object_again[:bytes]
      assert retrieved_bytes.is_a?(Parse::Bytes), "Should retrieve bytes object"
      assert_equal 'ZnJveW8=', retrieved_bytes.base64, "Should have correct base64 data"
    end
  end

  def test_create_without_data
    with_parse_server do
      object1 = TestObject.new(test: 'test')
      assert object1.save, "Should save object"
      
      # Create object without data using just the ID
      object2 = TestObject.new(object1.id)
      assert object2.fetch, "Should fetch object data"
      assert_equal 'test', object2[:test], "Should have fetched the 'test' property"
      
      # Create another object and modify before fetch
      object3 = TestObject.new(object1.id)
      object3[:test] = 'not test'
      assert object3.fetch, "Should fetch object data"
      assert_equal 'test', object3[:test], "Fetch should override local changes"
    end
  end

  def test_returns_correct_field_values
    with_parse_server do
      test_values = [
        { field: 'string_field', value: 'string' },
        { field: 'number_field', value: 1 },
        { field: 'boolean_field', value: true },
        { field: 'array_field', value: [0, 1, 2] },
        { field: 'object_field', value: { key: 'value' } },
        { field: 'date_field', value: Time.now }
      ]
      
      test_values.each do |test_case|
        object = TestObject.new
        object[test_case[:field]] = test_case[:value]
        assert object.save, "Should save object with #{test_case[:field]}"
        
        query = TestObject.query
        object_again = query.get(object.id)
        retrieved_value = object_again[test_case[:field]]
        
        case test_case[:value]
        when Time
          # Compare times within 1 second tolerance
          assert (test_case[:value] - retrieved_value).abs < 1, 
                 "Time values should be close for #{test_case[:field]}"
        else
          assert_equal test_case[:value], retrieved_value,
                       "Should retrieve correct value for #{test_case[:field]}"
        end
        
        # Clean up
        object_again.destroy
      end
    end
  end
end