require_relative "../../test_helper"

class TestCloudFunctionsIntegration < Minitest::Test
  extend Minitest::Spec::DSL

  def test_parse_call_function_basic_signature
    # Test that the method exists and accepts the expected parameters
    assert_respond_to Parse, :call_function
    assert_respond_to Parse, :call_function_with_session
    assert_respond_to Parse, :trigger_job
    assert_respond_to Parse, :trigger_job_with_session
  end

  def test_cloud_functions_api_module_included
    # Test that CloudFunctions API module provides the expected methods
    client = Parse::Client.new
    assert_respond_to client, :call_function
    assert_respond_to client, :call_function_with_session
    assert_respond_to client, :trigger_job
    assert_respond_to client, :trigger_job_with_session
  end

  def test_call_function_with_session_parameter_handling
    # This tests the parameter passing without actually making requests
    # We'll create a minimal mock to verify the method signature works
    
    # Mock just enough to verify the flow
    mock_client = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    
    mock_response.expect :error?, false
    mock_response.expect :result, { "result" => "success" }
    mock_client.expect :call_function, mock_response, ["test", {}, {:opts=>{:session_token=>"token"}}]
    
    Parse::Client.stub :client, mock_client do
      result = Parse.call_function("test", {}, session_token: "token")
      assert_equal "success", result
    end
    
    mock_client.verify
    mock_response.verify
  end

  def test_call_function_with_session_convenience_method
    # Test the convenience method
    mock_client = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    
    mock_response.expect :error?, false
    mock_response.expect :result, { "result" => "success" }
    mock_client.expect :call_function, mock_response, ["test", {}, {:opts=>{:session_token=>"token"}}]
    
    Parse::Client.stub :client, mock_client do
      result = Parse.call_function_with_session("test", {}, "token")
      assert_equal "success", result
    end
    
    mock_client.verify
    mock_response.verify
  end

  def test_call_function_error_handling
    # Test error response handling
    mock_client = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    
    mock_response.expect :error?, true
    mock_client.expect :call_function, mock_response, ["test", {}, {:opts=>{}}]
    
    Parse::Client.stub :client, mock_client do
      result = Parse.call_function("test")
      assert_nil result
    end
    
    mock_client.verify
    mock_response.verify
  end

  def test_call_function_raw_response
    # Test raw response option
    mock_client = Minitest::Mock.new
    mock_response = Minitest::Mock.new
    
    mock_client.expect :call_function, mock_response, ["test", {}, {:opts=>{}}]
    
    Parse::Client.stub :client, mock_client do
      result = Parse.call_function("test", {}, raw: true)
      assert_equal mock_response, result
    end
    
    mock_client.verify
  end
end