require_relative "../../test_helper"

class TestCountDistinct < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @mock_client = Minitest::Mock.new
    @query = Parse::Query.new("Song")
    @query.client = @mock_client
  end

  def test_count_distinct_basic
    # Mock successful response
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [{ "distinctCount" => 5 }]
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline], Hash
    
    result = @query.count_distinct(:genre)
    
    assert_equal 5, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_with_where_conditions
    # Add where condition
    @query.where(:play_count.gt => 100)
    
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true  
    mock_response.expect :result, [{ "distinctCount" => 3 }]
    
    expected_pipeline = [
      { "$match" => { "playCount" => { "$gt" => 100 } } },
      { "$group" => { "_id" => "$artist" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline], Hash
    
    result = @query.count_distinct(:artist)
    
    assert_equal 3, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_empty_result
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, []
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline], Hash
    
    result = @query.count_distinct(:genre)
    
    assert_equal 0, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_error_response
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, false
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline], Hash
    
    result = @query.count_distinct(:genre)
    
    assert_equal 0, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_nil_field_raises_error
    assert_raises(ArgumentError) do
      @query.count_distinct(nil)
    end
  end

  def test_count_distinct_invalid_field_raises_error
    assert_raises(ArgumentError) do
      @query.count_distinct({})
    end
  end

  def test_count_distinct_field_formatting
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [{ "distinctCount" => 2 }]
    
    # Test that snake_case field gets converted to camelCase
    expected_pipeline = [
      { "$group" => { "_id" => "$playCount" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline], Hash
    
    result = @query.count_distinct(:play_count)
    
    assert_equal 2, result
    @mock_client.verify
    mock_response.verify
  end
end