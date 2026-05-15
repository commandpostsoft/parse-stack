require_relative "../../test_helper"
require "parse/atlas_search"

# Tests pattern validation on Parse::AtlasSearch::SearchBuilder's wildcard
# and regex operators. Leading wildcards and oversized patterns are denial-
# of-service vectors against Atlas Search.
class AtlasSearchPatternValidationTest < Minitest::Test
  def setup
    @builder = Parse::AtlasSearch::SearchBuilder.new(index_name: "default")
  end

  def test_wildcard_accepts_normal_pattern
    @builder.wildcard(query: "prefix*", path: :title)
    op = @builder.operators.first
    assert_equal "prefix*", op["wildcard"]["query"]
  end

  def test_wildcard_rejects_leading_star
    err = assert_raises(ArgumentError) do
      @builder.wildcard(query: "*tail", path: :title)
    end
    assert_match(/leading wildcards/, err.message)
  end

  def test_wildcard_rejects_leading_question_mark
    assert_raises(ArgumentError) do
      @builder.wildcard(query: "?abc", path: :title)
    end
  end

  def test_wildcard_rejects_empty
    assert_raises(ArgumentError) { @builder.wildcard(query: "", path: :title) }
  end

  def test_wildcard_rejects_non_string
    assert_raises(ArgumentError) { @builder.wildcard(query: 123, path: :title) }
    assert_raises(ArgumentError) { @builder.wildcard(query: nil, path: :title) }
  end

  def test_wildcard_rejects_oversized
    pattern = "a" * (Parse::AtlasSearch::SearchBuilder::MAX_PATTERN_LENGTH + 1)
    err = assert_raises(ArgumentError) do
      @builder.wildcard(query: pattern, path: :title)
    end
    assert_match(/exceeds/, err.message)
  end

  def test_regex_accepts_anchored_pattern
    @builder.regex(query: "abc.*", path: :title)
    op = @builder.operators.first
    assert_equal "abc.*", op["regex"]["query"]
  end

  def test_regex_rejects_leading_dot_star
    err = assert_raises(ArgumentError) do
      @builder.regex(query: ".*abc", path: :title)
    end
    assert_match(/unbounded leading/, err.message)
  end

  def test_regex_rejects_leading_dot_plus
    assert_raises(ArgumentError) do
      @builder.regex(query: ".+abc", path: :title)
    end
  end

  def test_regex_rejects_leading_star
    assert_raises(ArgumentError) do
      @builder.regex(query: "*abc", path: :title)
    end
  end

  def test_regex_rejects_oversized
    pattern = "a" * (Parse::AtlasSearch::SearchBuilder::MAX_PATTERN_LENGTH + 1)
    assert_raises(ArgumentError) do
      @builder.regex(query: pattern, path: :title)
    end
  end

  def test_regex_rejects_empty
    assert_raises(ArgumentError) { @builder.regex(query: "", path: :title) }
  end
end
