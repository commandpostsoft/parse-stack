require_relative "../../../../test_helper"

class TestArraySizeConstraint < Minitest::Test
  extend Minitest::Spec::DSL
  include ConstraintTests

  def setup
    @klass = Parse::Constraint::ArraySizeConstraint
    @key = :$size
    @operand = :size
    @keys = [:size]
    @skip_scalar_values_test = true
  end

  def build(value)
    if value.is_a?(Integer) && value >= 0
      { "field" => { "$size" => value } }
    else
      { "field" => { @key.to_s => Parse::Constraint.formatted_value(value) } }
    end
  end

  def test_with_positive_integer
    constraint = @klass.new(:tags, 3)
    expected = { tags: { :$size => 3 } }
    assert_equal expected, constraint.build
  end

  def test_with_zero
    constraint = @klass.new(:tags, 0)
    expected = { tags: { :$size => 0 } }
    assert_equal expected, constraint.build
  end

  def test_invalid_negative_integer_raises_error
    constraint = @klass.new(:tags, -1)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_string_raises_error
    constraint = @klass.new(:tags, "3")
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_invalid_float_raises_error
    constraint = @klass.new(:tags, 3.5)
    assert_raises(ArgumentError) do
      constraint.build
    end
  end
end