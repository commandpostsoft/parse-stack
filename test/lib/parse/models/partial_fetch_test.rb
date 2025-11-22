require_relative '../../../test_helper'

# Test model for partial fetch unit testing
class PartialFetchTestModel < Parse::Object
  parse_class "PartialFetchTestModel"

  property :title, :string
  property :content, :string
  property :view_count, :integer, default: 0
  property :is_published, :boolean, default: false
  property :tags, :array, default: []

  belongs_to :author, as: :partial_fetch_test_user
end

class PartialFetchTestUser < Parse::Object
  parse_class "PartialFetchTestUser"

  property :name, :string
  property :email, :string
  property :age, :integer
end

class PartialFetchTest < Minitest::Test

  def test_partially_fetched_returns_false_when_no_keys_set
    obj = PartialFetchTestModel.new
    refute obj.partially_fetched?, "New object should not be partially fetched"
  end

  def test_partially_fetched_returns_true_when_keys_set
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title, :content]
    assert obj.partially_fetched?, "Object with fetched_keys should be partially fetched"
  end

  def test_fetched_keys_setter_normalizes_to_symbols
    obj = PartialFetchTestModel.new
    obj.fetched_keys = ["title", "content"]

    assert obj.fetched_keys.all? { |k| k.is_a?(Symbol) }, "All keys should be symbols"
  end

  def test_fetched_keys_setter_always_includes_id
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]

    assert obj.fetched_keys.include?(:id), "Should always include :id"
    assert obj.fetched_keys.include?(:objectId), "Should always include :objectId"
  end

  def test_fetched_keys_setter_handles_nil
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]
    obj.fetched_keys = nil

    refute obj.partially_fetched?, "Nil should clear partial fetch state"
  end

  def test_fetched_keys_setter_handles_empty_array
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]
    obj.fetched_keys = []

    refute obj.partially_fetched?, "Empty array should clear partial fetch state"
  end

  def test_fetched_keys_getter_returns_frozen_duplicate
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]

    keys = obj.fetched_keys
    assert keys.frozen?, "Returned array should be frozen"

    # Modifying the returned array should not affect internal state
    assert_raises(FrozenError) { keys << :new_key }
  end

  def test_field_was_fetched_returns_true_for_all_when_not_partial
    obj = PartialFetchTestModel.new

    assert obj.field_was_fetched?(:title), "All fields should be fetched when not partial"
    assert obj.field_was_fetched?(:content), "All fields should be fetched when not partial"
    assert obj.field_was_fetched?(:any_field), "Any field should be fetched when not partial"
  end

  def test_field_was_fetched_returns_true_for_fetched_fields
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title, :content]

    assert obj.field_was_fetched?(:title), "Fetched field should return true"
    assert obj.field_was_fetched?(:content), "Fetched field should return true"
  end

  def test_field_was_fetched_returns_false_for_unfetched_fields
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]

    refute obj.field_was_fetched?(:view_count), "Unfetched field should return false"
    refute obj.field_was_fetched?(:is_published), "Unfetched field should return false"
  end

  def test_field_was_fetched_always_true_for_base_keys
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]

    assert obj.field_was_fetched?(:id), "id should always be fetched"
    assert obj.field_was_fetched?(:created_at), "created_at should always be fetched"
    assert obj.field_was_fetched?(:updated_at), "updated_at should always be fetched"
    assert obj.field_was_fetched?(:acl), "acl should always be fetched"
  end

  def test_field_was_fetched_handles_string_keys
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]

    assert obj.field_was_fetched?("title"), "Should handle string keys"
    refute obj.field_was_fetched?("content"), "Should handle string keys"
  end

  def test_nested_fetched_keys_setter_and_getter
    obj = PartialFetchTestModel.new
    obj.nested_fetched_keys = { author: [:name, :email] }

    assert_equal({ author: [:name, :email] }, obj.nested_fetched_keys)
  end

  def test_nested_fetched_keys_setter_handles_non_hash
    obj = PartialFetchTestModel.new
    obj.nested_fetched_keys = "invalid"

    assert_equal({}, obj.nested_fetched_keys, "Non-hash should result in empty hash")
  end

  def test_nested_keys_for_returns_keys_for_field
    obj = PartialFetchTestModel.new
    obj.nested_fetched_keys = { author: [:name, :email], team: [:title] }

    assert_equal [:name, :email], obj.nested_keys_for(:author)
    assert_equal [:title], obj.nested_keys_for(:team)
  end

  def test_nested_keys_for_returns_nil_for_unknown_field
    obj = PartialFetchTestModel.new
    obj.nested_fetched_keys = { author: [:name] }

    assert_nil obj.nested_keys_for(:unknown)
  end

  def test_nested_keys_for_returns_nil_when_no_nested_keys
    obj = PartialFetchTestModel.new

    assert_nil obj.nested_keys_for(:author)
  end

  def test_clear_partial_fetch_state
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]
    obj.nested_fetched_keys = { author: [:name] }

    obj.clear_partial_fetch_state!

    refute obj.partially_fetched?, "Should no longer be partially fetched"
    assert_equal({}, obj.nested_fetched_keys, "Nested keys should be cleared")
  end

  def test_disable_autofetch
    obj = PartialFetchTestModel.new

    refute obj.autofetch_disabled?, "Autofetch should be enabled by default"

    obj.disable_autofetch!
    assert obj.autofetch_disabled?, "Autofetch should be disabled"

    obj.enable_autofetch!
    refute obj.autofetch_disabled?, "Autofetch should be re-enabled"
  end

  def test_parse_includes_to_nested_keys_simple
    query = PartialFetchTestModel.query

    result = query.send(:parse_includes_to_nested_keys, [:author, :"author.name"])

    assert result[:author].include?(:name), "author should include name"
  end

  def test_parse_includes_to_nested_keys_deep_nesting
    query = PartialFetchTestModel.query

    # For "a.b.c.d", each level should get the next level as its key
    result = query.send(:parse_includes_to_nested_keys, [:"a.b.c.d"])

    assert result[:a].include?(:b), "a should include b"
    assert result[:b].include?(:c), "b should include c"
    assert result[:c].include?(:d), "c should include d"
    assert result[:d] == [], "d should have empty array (leaf node)"
  end

  def test_parse_includes_to_nested_keys_multiple_paths
    query = PartialFetchTestModel.query

    result = query.send(:parse_includes_to_nested_keys, [
      :"team.manager.name",
      :"team.manager.email",
      :"team.address"
    ])

    assert result[:team].include?(:manager), "team should include manager"
    assert result[:team].include?(:address), "team should include address"
    assert result[:manager].include?(:name), "manager should include name"
    assert result[:manager].include?(:email), "manager should include email"
  end

  def test_parse_includes_to_nested_keys_empty_input
    query = PartialFetchTestModel.query

    assert_equal({}, query.send(:parse_includes_to_nested_keys, nil), "nil should return empty hash")
    assert_equal({}, query.send(:parse_includes_to_nested_keys, []), "empty array should return empty hash")
  end

  def test_build_sets_fetched_keys_before_initialize
    json = { "objectId" => "abc123", "title" => "Test" }

    # Build with fetched_keys
    obj = PartialFetchTestModel.build(json, "PartialFetchTestModel", fetched_keys: [:title])

    # Object should be partially fetched
    assert obj.partially_fetched?, "Built object should be partially fetched"
    assert obj.field_was_fetched?(:title), "title should be fetched"
  end

  def test_build_sets_nested_fetched_keys
    json = { "objectId" => "abc123", "title" => "Test" }
    nested = { author: [:name, :email] }

    obj = PartialFetchTestModel.build(json, "PartialFetchTestModel",
                                       fetched_keys: [:title],
                                       nested_fetched_keys: nested)

    assert_equal [:name, :email], obj.nested_keys_for(:author)
  end

  def test_query_decode_passes_keys_to_build
    # Create a query with keys
    query = PartialFetchTestModel.query.keys(:title)

    # The query should have @keys set
    assert query.instance_variable_get(:@keys).include?(:title), "Query should have keys"
  end

  def test_existed_returns_false_for_new_object
    obj = PartialFetchTestModel.new
    refute obj.existed?, "New object should not have existed"
  end

  def test_existed_with_same_timestamps
    obj = PartialFetchTestModel.new
    time = Time.now
    obj.instance_variable_set(:@created_at, time)
    obj.instance_variable_set(:@updated_at, time)

    refute obj.existed?, "Object with same timestamps should not have existed"
  end

  def test_field_was_fetched_with_nil_field_map_entry
    obj = PartialFetchTestModel.new
    obj.fetched_keys = [:title]

    # Test with a key that doesn't have a field_map entry
    refute obj.field_was_fetched?(:nonexistent_field), "Unknown field should not be fetched"
  end

  def test_accessing_unfetched_field_with_autofetch_disabled_raises_error
    obj = PartialFetchTestModel.new
    obj.id = "abc123"
    obj.fetched_keys = [:title]
    obj.disable_autofetch!

    error = assert_raises(Parse::UnfetchedFieldAccessError) do
      obj.content
    end

    assert_equal :content, error.field_name
    assert_equal "PartialFetchTestModel", error.object_class
    assert_match(/content/, error.message)
    assert_match(/autofetch disabled/, error.message)
  end

  def test_accessing_fetched_field_with_autofetch_disabled_does_not_raise_error
    obj = PartialFetchTestModel.new
    obj.id = "abc123"
    # Set title via instance variable to avoid triggering autofetch during dirty tracking
    obj.instance_variable_set(:@title, "Test Title")
    obj.fetched_keys = [:title]
    obj.disable_autofetch!

    # Should not raise - title was fetched
    assert_equal "Test Title", obj.title
  end

  def test_accessing_field_on_non_partial_object_with_autofetch_disabled_does_not_raise
    obj = PartialFetchTestModel.new
    obj.id = "abc123"
    obj.disable_autofetch!

    # Should not raise - object is not partially fetched
    assert_nil obj.content
  end

  def test_accessing_base_keys_with_autofetch_disabled_does_not_raise
    obj = PartialFetchTestModel.new
    obj.id = "abc123"
    obj.fetched_keys = [:title]
    obj.disable_autofetch!

    # Base keys should always be accessible
    assert_equal "abc123", obj.id
    assert_nil obj.created_at
    assert_nil obj.updated_at
  end

  def test_re_enabling_autofetch_allows_access_without_error
    obj = PartialFetchTestModel.new
    obj.id = "abc123"
    obj.fetched_keys = [:title]
    obj.disable_autofetch!
    obj.enable_autofetch!

    # After re-enabling, accessing unfetched field should NOT raise UnfetchedFieldAccessError
    # It will try to autofetch and may fail with ConnectionError (no Parse server),
    # but that's expected and different from the access error
    begin
      obj.content
    rescue Parse::UnfetchedFieldAccessError
      flunk "Should not raise UnfetchedFieldAccessError after re-enabling autofetch"
    rescue Parse::Error::ConnectionError
      # Expected - autofetch was attempted but no server configured
      pass
    end
  end
end
