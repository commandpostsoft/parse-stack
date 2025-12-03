# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/autorun"

# Test model for collection proxy as_json testing
class CollectionTestSong < Parse::Object
  parse_class "CollectionTestSong"
  property :title, :string
  property :tags, :array           # Regular array (strings)
  property :related_songs, :array  # Array that will contain pointers
end

class CollectionProxyAsJsonTest < Minitest::Test
  def setup
    @song1 = CollectionTestSong.new(id: "song123", title: "Song 1")
    @song2 = CollectionTestSong.new(id: "song456", title: "Song 2")
    @pointer1 = Parse::Pointer.new("CollectionTestSong", "song789")
  end

  # === Regular Arrays (Primitives) ===

  def test_as_json_with_string_array
    proxy = Parse::CollectionProxy.new(["rock", "pop", "jazz"])

    result = proxy.as_json

    assert_equal ["rock", "pop", "jazz"], result
  end

  def test_as_json_with_integer_array
    proxy = Parse::CollectionProxy.new([1, 2, 3, 100])

    result = proxy.as_json

    assert_equal [1, 2, 3, 100], result
  end

  def test_as_json_with_mixed_primitives
    proxy = Parse::CollectionProxy.new(["hello", 42, true, 3.14])

    result = proxy.as_json

    assert_equal ["hello", 42, true, 3.14], result
  end

  def test_as_json_with_empty_array
    proxy = Parse::CollectionProxy.new([])

    result = proxy.as_json

    assert_equal [], result
  end

  # === Default behavior (full objects for API responses) ===

  def test_as_json_default_preserves_full_objects
    proxy = Parse::CollectionProxy.new([@song1, @song2])

    result = proxy.as_json

    # Default: should preserve full object serialization
    assert_equal 2, result.length
    # Objects serialize via their as_json which includes objectId
    result.each do |item|
      assert item.is_a?(Hash)
      assert item["objectId"].present? || item[:objectId].present?
    end
  end

  # === pointers_only: true (for storage/Parse webhooks) ===

  def test_as_json_pointers_only_converts_parse_objects
    proxy = Parse::CollectionProxy.new([@song1, @song2])

    result = proxy.as_json(pointers_only: true)

    expected = [
      { "__type" => "Pointer", "className" => "CollectionTestSong", "objectId" => "song123" },
      { "__type" => "Pointer", "className" => "CollectionTestSong", "objectId" => "song456" },
    ]
    assert_equal expected, result
  end

  def test_as_json_pointers_only_converts_single_object
    proxy = Parse::CollectionProxy.new([@song1])

    result = proxy.as_json(pointers_only: true)

    assert_equal 1, result.length
    assert_equal "Pointer", result[0]["__type"]
    assert_equal "CollectionTestSong", result[0]["className"]
    assert_equal "song123", result[0]["objectId"]
  end

  def test_as_json_pointers_only_converts_pointers
    proxy = Parse::CollectionProxy.new([@pointer1])

    result = proxy.as_json(pointers_only: true)

    expected = [
      { "__type" => "Pointer", "className" => "CollectionTestSong", "objectId" => "song789" },
    ]
    assert_equal expected, result
  end

  def test_as_json_pointers_only_with_mixed_objects_and_pointers
    proxy = Parse::CollectionProxy.new([@song1, @pointer1, @song2])

    result = proxy.as_json(pointers_only: true)

    assert_equal 3, result.length
    result.each do |item|
      assert_equal "Pointer", item["__type"]
      assert_equal "CollectionTestSong", item["className"]
      assert item["objectId"].present?
    end
  end

  def test_as_json_pointers_only_preserves_primitives
    proxy = Parse::CollectionProxy.new(["rock", "pop", 42])

    result = proxy.as_json(pointers_only: true)

    # Primitives don't respond to :pointer, so they stay as-is
    assert_equal ["rock", "pop", 42], result
  end

  # === Hash Values ===

  def test_as_json_with_hash_values
    proxy = Parse::CollectionProxy.new([{ key: "value" }, { foo: "bar" }])

    result = proxy.as_json

    assert_equal [{ "key" => "value" }, { "foo" => "bar" }], result
  end

  # === Verify pointer format is correct ===

  def test_pointer_format_has_correct_keys
    proxy = Parse::CollectionProxy.new([@song1])

    result = proxy.as_json(pointers_only: true)

    assert_equal %w[__type className objectId].sort, result[0].keys.sort
  end

  # === PointerCollectionProxy backwards compatibility ===

  def test_pointer_collection_proxy_still_works
    proxy = Parse::PointerCollectionProxy.new([@song1, @song2])

    result = proxy.as_json

    # PointerCollectionProxy always converts to pointers
    assert_equal 2, result.length
    result.each do |item|
      assert_equal "Pointer", item["__type"]
    end
  end

  # === String option key works too ===

  def test_as_json_pointers_only_with_string_key
    proxy = Parse::CollectionProxy.new([@song1])

    result = proxy.as_json("pointers_only" => true)

    assert_equal "Pointer", result[0]["__type"]
  end
end
