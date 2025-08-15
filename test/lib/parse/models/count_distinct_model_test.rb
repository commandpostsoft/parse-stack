require_relative "../../../test_helper"

# Define a test model for count_distinct testing
class Song < Parse::Object
  property :title
  property :genre
  property :artist
  property :play_count, :integer
end

class TestCountDistinctModel < Minitest::Test
  extend Minitest::Spec::DSL

  def setup
    @mock_client = Minitest::Mock.new
    # Mock the client method to return our mock client
    Parse::Client.stub :client, @mock_client do
      # The block is empty because we're just setting up the stub
    end
  end

  def test_model_count_distinct_basic
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [{ "distinctCount" => 8 }]
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline]
    
    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Song.count_distinct(:genre)
    end
    
    assert_equal 8, result
    @mock_client.verify 
    mock_response.verify
  end

  def test_model_count_distinct_with_constraints
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [{ "distinctCount" => 4 }]
    
    expected_pipeline = [
      { "$match" => { "playCount" => { "$gt" => 1000 } } },
      { "$group" => { "_id" => "$artist" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline]
    
    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Song.count_distinct(:artist, :play_count.gt => 1000)
    end
    
    assert_equal 4, result
    @mock_client.verify
    mock_response.verify
  end

  def test_model_count_distinct_multiple_constraints
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, [{ "distinctCount" => 2 }]
    
    expected_pipeline = [
      { "$match" => { 
          "playCount" => { "$gt" => 500 }, 
          "genre" => "rock"
        } 
      },
      { "$group" => { "_id" => "$artist" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline]
    
    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Song.count_distinct(:artist, :play_count.gt => 500, :genre => "rock")
    end
    
    assert_equal 2, result
    @mock_client.verify
    mock_response.verify
  end

  def test_model_count_distinct_zero_result
    mock_response = Minitest::Mock.new
    mock_response.expect :success?, true
    mock_response.expect :result, []
    
    expected_pipeline = [
      { "$group" => { "_id" => "$genre" } },
      { "$count" => "distinctCount" }
    ]
    
    @mock_client.expect :aggregate_pipeline, mock_response, ["Song", expected_pipeline]
    
    result = nil
    Parse::Client.stub :client, @mock_client do
      result = Song.count_distinct(:genre)
    end
    
    assert_equal 0, result
    @mock_client.verify
    mock_response.verify
  end

  def test_count_distinct_method_exists_on_model
    assert_respond_to Song, :count_distinct
  end
end