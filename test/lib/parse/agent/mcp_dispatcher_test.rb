# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_dispatcher"

# ---------------------------------------------------------------------------
# Stub Parse::Agent for unit tests — no real Parse Server required.
# ---------------------------------------------------------------------------
class StubAgent
  STUB_TOOL_DEFS = [
    {
      "name"        => "query_class",
      "description" => "Query objects in a Parse class",
      "inputSchema" => { "type" => "object" },
    },
  ].freeze

  def tool_definitions(format: :mcp)
    STUB_TOOL_DEFS
  end

  def execute(tool_name, **kwargs)
    case tool_name
    when :get_all_schemas
      { success: true, data: { classes: [
        { name: "Song",  description: "Music tracks", type: "Custom" },
        { name: "_User", description: "Auth users",   type: "System" },
      ] } }
    when :get_schema
      { success: true, data: { className: kwargs[:class_name], fields: {} } }
    when :count_objects
      { success: true, data: { count: 42 } }
    when :get_sample_objects
      { success: true, data: { results: [] } }
    when :query_class
      { success: true, data: { results: [{ "objectId" => "abc123" }] } }
    when :fail_tool
      { success: false, error: "Something went wrong in the tool" }
    else
      { success: false, error: "Unknown tool: #{tool_name}" }
    end
  end
end

class ErrorAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise Parse::Agent::Unauthorized, "No token provided"
  end
end

class SecurityAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise Parse::Agent::SecurityError, "Blocked operator $where"
  end
end

class ValidationAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise Parse::Agent::ValidationError, "class_name is required"
  end
end

class StandardErrorAgent < StubAgent
  def execute(tool_name, **kwargs)
    raise RuntimeError, "Internal database connection failure details"
  end
end

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
class MCPDispatcherTest < Minitest::Test
  D = Parse::Agent::MCPDispatcher

  def setup
    @agent = StubAgent.new

    # Guard: mcp_rack_app_test.rb and mcp_streaming_test.rb both install
    # singleton-method stubs on MCPDispatcher.call at file-load time and restore
    # only in Minitest.after_run. When these files are loaded into the same
    # process (e.g. a "test all" rake task), the stub is active here and
    # would short-circuit every dispatch to a canned response. Restore the real
    # implementation for the duration of each dispatcher test.
    if defined?(MCPDispatcherStub) && MCPDispatcherStub.instance_variable_get(:@original_call)
      MCPDispatcherStub.restore!
      @mcp_stub_was_active = true
    else
      @mcp_stub_was_active = false
    end

    if defined?(StreamingDispatcherStub) && StreamingDispatcherStub.instance_variable_get(:@original)
      StreamingDispatcherStub.restore!
      @streaming_stub_was_active = true
    else
      @streaming_stub_was_active = false
    end

    # Register a custom test prompt using the real Prompts.register API.
    # This exercises the extension point and isolates tests from builtin changes.
    Parse::Agent::Prompts.register(
      name:        "test_prompt",
      description: "A test prompt",
      arguments:   [{ "name" => "class_name", "description" => "Parse class", "required" => true }],
      renderer:    lambda { |args|
        cn = args["class_name"].to_s
        raise Parse::Agent::ValidationError, "missing required argument: class_name" if cn.empty?
        "Describe the #{cn} Parse class."
      },
    )
  end

  def teardown
    Parse::Agent::Prompts.reset_registry!

    # Re-install each stub if it was active before setup, so the stub's owner
    # test class still sees it if it runs after us in the same process.
    if @mcp_stub_was_active && defined?(MCPDispatcherStub)
      MCPDispatcherStub.install!
    end
    if @streaming_stub_was_active && defined?(StreamingDispatcherStub)
      StreamingDispatcherStub.install!
    end
  end

  # ---------- initialize ----------------------------------------------------

  def test_initialize_returns_protocol_version
    body   = { "jsonrpc" => "2.0", "id" => 1, "method" => "initialize", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    env = result[:body]
    assert_equal "2.0", env["jsonrpc"]
    assert_equal 1,     env["id"]
    assert_equal Parse::Agent::MCPDispatcher::PROTOCOL_VERSION, env["result"]["protocolVersion"]
    assert_equal "parse-stack-mcp", env["result"]["serverInfo"]["name"]
  end

  def test_protocol_version_constant_matches_mcp_server
    assert_equal "2024-11-05", Parse::Agent::MCPDispatcher::PROTOCOL_VERSION
  end

  # ---------- ping ----------------------------------------------------------

  def test_ping_returns_empty_result
    body   = { "jsonrpc" => "2.0", "id" => 2, "method" => "ping" }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal({}, result[:body]["result"])
    refute result[:body].key?("error")
  end

  # ---------- tools/list ----------------------------------------------------

  def test_tools_list_returns_agent_definitions
    body   = { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    tools = result[:body]["result"]["tools"]
    assert_instance_of Array, tools
    assert_equal "query_class", tools.first["name"]
  end

  # ---------- tools/call — success ------------------------------------------

  def test_tools_call_success_executes_tool_and_returns_content
    body = {
      "jsonrpc" => "2.0",
      "id"      => 4,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => { "class_name" => "Song" } },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    r = result[:body]["result"]
    assert_equal false, r["isError"]
    assert_equal "text", r["content"].first["type"]
    # Content text should contain the JSON-serialized data
    assert_includes r["content"].first["text"], "abc123"
  end

  # ---------- tools/call — tool-level failure (isError: true) ---------------

  def test_tools_call_tool_failure_returns_is_error_true_not_jsonrpc_error
    # Build an agent that always returns success:false from execute
    failing_agent = Class.new(StubAgent) do
      def execute(tool_name, **kwargs)
        { success: false, error: "Simulated tool failure" }
      end
    end.new

    body = {
      "jsonrpc" => "2.0",
      "id"      => 5,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: failing_agent)

    assert_equal 200, result[:status]
    r = result[:body]["result"]
    # Must be a result envelope with isError: true, NOT a JSON-RPC error field
    assert_equal true, r["isError"]
    refute result[:body].key?("error"), "tool failure must not produce a JSON-RPC error field"
    assert_includes r["content"].first["text"], "Simulated tool failure"
  end

  # ---------- tools/call — missing tool name --------------------------------

  def test_tools_call_without_name_returns_invalid_params
    body = {
      "jsonrpc" => "2.0",
      "id"      => 6,
      "method"  => "tools/call",
      "params"  => { "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32602, result[:body]["error"]["code"])
  end

  # ---------- unknown method → -32601 and HTTP 200 --------------------------

  def test_unknown_method_returns_32601_with_http_200
    body   = { "jsonrpc" => "2.0", "id" => 7, "method" => "no_such_method/v99" }
    result = D.call(body: body, agent: @agent)

    # HTTP status must still be 200 for JSON-RPC error responses
    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32601, err["code"])
    assert_includes err["message"], "no_such_method/v99"
  end

  # ---------- malformed body → -32700 ---------------------------------------

  def test_missing_method_key_returns_32700
    body   = { "jsonrpc" => "2.0", "id" => 8 }  # no "method"
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32700, result[:body]["error"]["code"])
  end

  def test_non_hash_body_returns_32700_with_nil_id
    result = D.call(body: "not a hash", agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32700, result[:body]["error"]["code"])
    assert_nil result[:body]["id"]
  end

  # ---------- Unauthorized → HTTP 401 + -32001 ------------------------------

  def test_unauthorized_error_returns_401
    body = {
      "jsonrpc" => "2.0",
      "id"      => 9,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: ErrorAgent.new)

    assert_equal 401, result[:status]
    assert_equal(-32001, result[:body]["error"]["code"])
    assert_equal "Unauthorized", result[:body]["error"]["message"]
  end

  # ---------- SecurityError → HTTP 200 + -32602, no message leakage ---------

  def test_security_error_returns_32602_without_leaking_details
    body = {
      "jsonrpc" => "2.0",
      "id"      => 10,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    result = D.call(body: body, agent: SecurityAgent.new)

    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32602, err["code"])
    # The blocked operator detail must NOT appear in the message
    refute_includes err["message"].to_s, "where"
  end

  # ---------- StandardError → -32603 with sanitized "Internal error" --------

  def test_standard_error_returns_32603_with_sanitized_message
    body = {
      "jsonrpc" => "2.0",
      "id"      => 11,
      "method"  => "tools/call",
      "params"  => { "name" => "query_class", "arguments" => {} },
    }
    # Capture STDERR so the dispatcher's diagnostic warn line doesn't litter
    # test output. The class+message belong in operator logs, not on the wire.
    original_stderr = $stderr
    $stderr = StringIO.new
    begin
      result = D.call(body: body, agent: StandardErrorAgent.new)
    ensure
      $stderr = original_stderr
    end

    assert_equal 200, result[:status]
    err = result[:body]["error"]
    assert_equal(-32603, err["code"])
    # Body must NOT leak exception class name (gem fingerprinting) or details.
    assert_equal "Internal error", err["message"]
    refute_includes err["message"], "RuntimeError"
    refute_includes err["message"], "database connection failure details"
  end

  # ---------- resources/list ------------------------------------------------

  def test_resources_list_returns_three_resources_per_class
    body   = { "jsonrpc" => "2.0", "id" => 12, "method" => "resources/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    resources = result[:body]["result"]["resources"]
    # StubAgent returns 2 classes; 3 resources each = 6
    assert_equal 6, resources.size
    uris = resources.map { |r| r["uri"] }
    assert_includes uris, "parse://Song/schema"
    assert_includes uris, "parse://Song/count"
    assert_includes uris, "parse://Song/samples"
  end

  # ---------- resources/read ------------------------------------------------

  def test_resources_read_schema_returns_contents
    body = {
      "jsonrpc" => "2.0",
      "id"      => 13,
      "method"  => "resources/read",
      "params"  => { "uri" => "parse://Song/schema" },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    contents = result[:body]["result"]["contents"]
    assert_equal 1, contents.size
    assert_equal "parse://Song/schema", contents.first["uri"]
    assert_equal "application/json", contents.first["mimeType"]
  end

  def test_resources_read_invalid_uri_returns_32602
    body = {
      "jsonrpc" => "2.0",
      "id"      => 14,
      "method"  => "resources/read",
      "params"  => { "uri" => "http://evil.com/../../etc/passwd" },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32602, result[:body]["error"]["code"])
  end

  # ---------- prompts/list --------------------------------------------------

  def test_prompts_list_delegates_to_prompts_module
    body   = { "jsonrpc" => "2.0", "id" => 15, "method" => "prompts/list", "params" => {} }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    prompts = result[:body]["result"]["prompts"]
    assert_instance_of Array, prompts
    # Our registered custom prompt must appear in the list.
    # Registered prompts are appended after builtins, so we check inclusion.
    prompt_names = prompts.map { |p| p["name"] }
    assert_includes prompt_names, "test_prompt", "registered test_prompt must appear in prompts list"
    # Builtins must also be present
    assert_includes prompt_names, "parse_conventions"
  end

  # ---------- prompts/get — success ----------------------------------------

  def test_prompts_get_renders_known_prompt
    body = {
      "jsonrpc" => "2.0",
      "id"      => 16,
      "method"  => "prompts/get",
      "params"  => { "name" => "test_prompt", "arguments" => { "class_name" => "Song" } },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    # Prompts.render returns the full MCP envelope; dispatcher passes it through as-is.
    r = result[:body]["result"]
    # description comes from Prompts.render (builtin or custom)
    assert_instance_of String, r["description"]
    # messages array with a user role entry
    assert_instance_of Array, r["messages"]
    msg = r["messages"].first
    assert_equal "user", msg["role"]
    # The rendered text should contain our class name
    assert_includes msg["content"]["text"], "Song"
  end

  # ---------- prompts/get — unknown prompt ----------------------------------

  def test_prompts_get_unknown_prompt_returns_32602
    body = {
      "jsonrpc" => "2.0",
      "id"      => 17,
      "method"  => "prompts/get",
      "params"  => { "name" => "no_such_prompt", "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    # Prompts.render raises ValidationError("Unknown prompt: no_such_prompt")
    # which dispatch maps to -32602 preserving the message.
    assert_equal(-32602, result[:body]["error"]["code"])
    assert_includes result[:body]["error"]["message"], "Unknown prompt"
  end

  # ---------- prompts/get — missing required argument -----------------------

  def test_prompts_get_missing_required_argument_returns_32602
    body = {
      "jsonrpc" => "2.0",
      "id"      => 18,
      "method"  => "prompts/get",
      "params"  => { "name" => "test_prompt", "arguments" => {} },
    }
    result = D.call(body: body, agent: @agent)

    assert_equal 200, result[:status]
    assert_equal(-32602, result[:body]["error"]["code"])
    assert_includes result[:body]["error"]["message"], "class_name"
  end

  # ---------- envelope structure --------------------------------------------

  def test_response_always_has_jsonrpc_and_id_keys
    body   = { "jsonrpc" => "2.0", "id" => "req-abc", "method" => "ping" }
    result = D.call(body: body, agent: @agent)

    env = result[:body]
    assert env.key?("jsonrpc"), "envelope must have jsonrpc key"
    assert env.key?("id"),      "envelope must have id key"
    assert_equal "2.0",       env["jsonrpc"]
    assert_equal "req-abc",   env["id"]
  end

  def test_successful_response_has_result_not_error
    body   = { "jsonrpc" => "2.0", "id" => 19, "method" => "ping" }
    result = D.call(body: body, agent: @agent)

    assert result[:body].key?("result"), "success must have result key"
    refute result[:body].key?("error"),  "success must not have error key"
  end
end
