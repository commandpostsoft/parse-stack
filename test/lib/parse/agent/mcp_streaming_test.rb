# encoding: UTF-8
# frozen_string_literal: true

require "stringio"
require "json"
require "securerandom"
require_relative "../../../test_helper"
require_relative "../../../../lib/parse/agent/mcp_rack_app"

# ---------------------------------------------------------------------------
# MCPStreamingTest — unit tests for SSE streaming support in MCPRackApp.
#
# MCPDispatcher.call is stubbed with a controllable implementation so tests
# can induce a realistic dispatch delay without relying on a live Parse server.
# The stub is installed only for the duration of this test file's run.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Controlled stub for MCPDispatcher.call used by streaming tests.
# The `delay` field causes the stub to sleep before returning, giving the
# heartbeat timer enough time to fire at least once.
#
# Unlike MCPDispatcherStub in mcp_rack_app_test.rb, this stub is installed
# and restored per-test (in setup/teardown) rather than at file-load time.
# This avoids cross-test pollution when multiple MCP test files are loaded
# into the same Ruby process (e.g. during rake test:unit).
# ---------------------------------------------------------------------------
module StreamingDispatcherStub
  FIXED_RESPONSE = {
    status: 200,
    body: { "jsonrpc" => "2.0", "id" => 1, "result" => { "tools" => [] } },
  }.freeze

  class << self
    attr_accessor :delay, :response, :raise_error

    def install!
      @original    = Parse::Agent::MCPDispatcher.method(:call)
      @delay       = 0
      @response    = nil
      @raise_error = nil

      Parse::Agent::MCPDispatcher.define_singleton_method(:call) do |body:, agent:, logger: nil, progress_callback: nil|
        delay = StreamingDispatcherStub.delay || 0
        sleep delay if delay > 0
        if (err = StreamingDispatcherStub.raise_error)
          raise err
        end
        StreamingDispatcherStub.response || StreamingDispatcherStub::FIXED_RESPONSE
      end
    end

    def restore!
      if @original
        original = @original
        Parse::Agent::MCPDispatcher.define_singleton_method(:call, &original)
      end
      @delay       = 0
      @response    = nil
      @raise_error = nil
      @original    = nil
    end

    def installed?
      !@original.nil?
    end
  end
end

class MCPStreamingTest < Minitest::Test
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def setup
    unless Parse::Client.client?
      Parse.setup(
        server_url:     "http://localhost:1337/parse",
        application_id: "test-app-id",
        api_key:        "test-api-key",
      )
    end

    # Install per-test so the stub does not bleed into other test files when
    # multiple MCP test files are loaded in the same process.
    StreamingDispatcherStub.install!
  end

  def teardown
    StreamingDispatcherStub.restore!
  end

  # Minimal Rack env. `accept` overrides HTTP_ACCEPT.
  def rack_env(body: JSON.generate({ "jsonrpc" => "2.0", "id" => 1, "method" => "ping" }),
               accept: nil,
               method: "POST",
               content_type: "application/json")
    env = {
      "REQUEST_METHOD" => method,
      "CONTENT_TYPE"   => content_type,
      "rack.input"     => StringIO.new(body),
    }
    env["HTTP_ACCEPT"] = accept if accept
    env
  end

  def valid_agent
    Parse::Agent.new
  end

  def permissive_factory
    ->(_env) { valid_agent }
  end

  # Build a streaming-enabled app with a very short heartbeat interval for tests.
  def streaming_app(heartbeat_interval: 0.1, **kwargs)
    Parse::Agent::MCPRackApp.new(
      agent_factory:      permissive_factory,
      streaming:          true,
      heartbeat_interval: heartbeat_interval,
      **kwargs,
    )
  end

  # Build a non-streaming app (the default).
  def plain_app(**kwargs)
    Parse::Agent::MCPRackApp.new(agent_factory: permissive_factory, **kwargs)
  end

  # Drain a Rack body object into an array of strings.
  def drain_body(body)
    chunks = []
    body.each { |c| chunks << c }
    chunks
  rescue => e
    # Surface drain errors in test output without swallowing the test
    chunks << "DRAIN_ERROR:#{e.class}:#{e.message}"
    chunks
  end

  # Parse SSE event chunks. Returns an array of { event:, data: } hashes.
  def parse_sse_chunks(chunks)
    events = []
    chunks.each do |chunk|
      chunk.scan(/event:\s*(\S+)\ndata:\s*(.+?)(?=\n\n|\z)/m) do |event, data|
        events << { event: event, data: data }
      end
    end
    events
  end

  # ---------------------------------------------------------------------------
  # 1. Default (streaming: false) — SSE Accept returns plain JSON
  # ---------------------------------------------------------------------------

  def test_default_streaming_false_sse_accept_returns_json
    app = plain_app
    status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
    chunks = drain_body(body)
    parsed = JSON.parse(chunks.join)
    assert parsed.key?("result"), "Expected a JSON-RPC result envelope, got: #{parsed.inspect}"
  end

  def test_default_streaming_false_no_accept_returns_json
    app = plain_app
    status, headers, _body = app.call(rack_env)

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 2. streaming: true, no SSE Accept — still returns plain JSON
  # ---------------------------------------------------------------------------

  def test_streaming_true_without_sse_accept_returns_json
    app = streaming_app
    status, headers, _body = app.call(rack_env)

    assert_equal 200, status
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 3. streaming: true + Accept: text/event-stream — returns SSE Content-Type
  # ---------------------------------------------------------------------------

  def test_streaming_true_with_sse_accept_returns_event_stream_content_type
    app = streaming_app
    status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    body.close if body.respond_to?(:close)
    # Drain to completion so the worker thread cleans up before we assert
    drain_body(body) rescue nil

    assert_equal 200, status
    assert_equal "text/event-stream", headers["Content-Type"]
    assert_equal "no-cache", headers["Cache-Control"]
    assert_equal "keep-alive", headers["Connection"]
    assert_equal "no", headers["X-Accel-Buffering"]
  end

  # ---------------------------------------------------------------------------
  # 4. Streamed body contains at least one progress event and exactly one response
  # ---------------------------------------------------------------------------

  def test_streamed_body_contains_progress_and_response_events
    # Heartbeat every 0.1s; dispatcher sleeps 0.25s so at least 1 heartbeat fires.
    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)

    progress_events = events.select { |e| e[:event] == "progress" }
    response_events = events.select { |e| e[:event] == "response" }

    assert progress_events.size >= 1,
           "Expected at least 1 progress event, got #{progress_events.size}. " \
           "Events: #{events.map { |e| e[:event] }.inspect}"
    assert_equal 1, response_events.size,
                 "Expected exactly 1 response event, got #{response_events.size}"
  end

  # ---------------------------------------------------------------------------
  # 5. Response event payload matches what plain JSON path would return
  # ---------------------------------------------------------------------------

  def test_response_event_payload_matches_plain_json_response
    fixed = {
      status: 200,
      body: { "jsonrpc" => "2.0", "id" => 7, "result" => { "count" => 42 } },
    }
    StreamingDispatcherStub.response = fixed

    # Plain JSON path
    plain = plain_app
    _s, _h, plain_body = plain.call(rack_env)
    plain_parsed = JSON.parse(drain_body(plain_body).join)

    # SSE path
    app = streaming_app(heartbeat_interval: 0.1)
    _s2, _h2, sse_body_obj = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(sse_body_obj)

    events = parse_sse_chunks(chunks)
    response_event = events.find { |e| e[:event] == "response" }
    refute_nil response_event, "No response event in SSE stream"

    sse_parsed = JSON.parse(response_event[:data])

    assert_equal plain_parsed["jsonrpc"], sse_parsed["jsonrpc"]
    assert_equal plain_parsed["id"],     sse_parsed["id"]
    assert_equal plain_parsed["result"], sse_parsed["result"]
  end

  # ---------------------------------------------------------------------------
  # 6. Unauthorized factory raises BEFORE any SSE stream — returns plain 401 JSON
  # ---------------------------------------------------------------------------

  def test_unauthorized_factory_returns_plain_401_not_sse
    factory = ->(_env) { raise Parse::Agent::Unauthorized, "bad token" }
    app = Parse::Agent::MCPRackApp.new(
      agent_factory:      factory,
      streaming:          true,
      heartbeat_interval: 0.1,
    )

    status, headers, body = app.call(rack_env(accept: "text/event-stream"))

    assert_equal 401, status
    assert_equal "application/json", headers["Content-Type"],
                 "Unauthorized should always return application/json, not SSE"

    parsed = JSON.parse(drain_body(body).join)
    assert_equal(-32_001, parsed.dig("error", "code"))
    assert_equal "Unauthorized", parsed.dig("error", "message")
  end

  # ---------------------------------------------------------------------------
  # 7. No leaked threads after stream completes
  # ---------------------------------------------------------------------------

  def test_no_leaked_threads_after_stream_completes
    # Allow the dispatcher to finish quickly so there's nothing to leak.
    StreamingDispatcherStub.delay = 0

    threads_before = Thread.list.size

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    drain_body(body)

    # Give the worker thread a moment to exit after the queue sentinel is pushed.
    sleep 0.05

    threads_after = Thread.list.size

    assert_equal threads_before, threads_after,
                 "Expected no new threads after stream completes. " \
                 "Before: #{threads_before}, After: #{threads_after}"
  end

  # ---------------------------------------------------------------------------
  # 8. progressToken is read from params._meta.progressToken when supplied
  # ---------------------------------------------------------------------------

  def test_progress_token_from_request_params
    token = "client-supplied-token-#{SecureRandom.hex(4)}"
    request_body = JSON.generate({
      "jsonrpc" => "2.0",
      "id"      => 10,
      "method"  => "tools/call",
      "params"  => {
        "name"      => "ping",
        "arguments" => {},
        "_meta"     => { "progressToken" => token },
      },
    })

    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(body: request_body, accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }

    assert progress_events.size >= 1, "Expected at least one progress event"

    progress_events.each do |pe|
      data = JSON.parse(pe[:data])
      assert_equal token, data.dig("params", "progressToken"),
                   "Progress event should carry the client-supplied token"
    end
  end

  # ---------------------------------------------------------------------------
  # 9. Auto-generated progressToken when not supplied
  # ---------------------------------------------------------------------------

  def test_progress_token_auto_generated_when_absent
    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress_events = events.select { |e| e[:event] == "progress" }

    assert progress_events.size >= 1, "Expected at least one progress event"

    token = JSON.parse(progress_events.first[:data]).dig("params", "progressToken")
    refute_nil token, "progressToken must be present even when not supplied by client"
    refute_empty token
  end

  # ---------------------------------------------------------------------------
  # 10. Transport-level errors (405/415/413/400) return plain JSON regardless
  # ---------------------------------------------------------------------------

  def test_405_returns_plain_json_regardless_of_accept
    app = streaming_app
    status, headers, _body = app.call(rack_env(method: "GET", accept: "text/event-stream"))
    assert_equal 405, status
    assert_equal "application/json", headers["Content-Type"]
  end

  def test_415_returns_plain_json_regardless_of_accept
    app = streaming_app
    env = rack_env(accept: "text/event-stream", content_type: "text/plain")
    status, headers, _body = app.call(env)
    assert_equal 415, status
    assert_equal "application/json", headers["Content-Type"]
  end

  def test_413_returns_plain_json_regardless_of_accept
    max = Parse::Agent::MCPRackApp::DEFAULT_MAX_BODY_SIZE
    app = streaming_app
    env = rack_env(body: "x" * (max + 1), accept: "text/event-stream")
    status, headers, _body = app.call(env)
    assert_equal 413, status
    assert_equal "application/json", headers["Content-Type"]
  end

  def test_400_returns_plain_json_regardless_of_accept
    app = streaming_app
    env = rack_env(body: "{bad json", accept: "text/event-stream")
    status, headers, _body = app.call(env)
    assert_equal 400, status
    assert_equal "application/json", headers["Content-Type"]
  end

  # ---------------------------------------------------------------------------
  # 11. Progress events carry correct JSON-RPC notification shape
  # ---------------------------------------------------------------------------

  def test_progress_events_have_correct_jsonrpc_notification_shape
    StreamingDispatcherStub.delay = 0.25

    app = streaming_app(heartbeat_interval: 0.1)
    _status, _headers, body = app.call(rack_env(accept: "text/event-stream"))
    chunks = drain_body(body)

    events = parse_sse_chunks(chunks)
    progress = events.select { |e| e[:event] == "progress" }

    assert progress.size >= 1

    progress.each do |pe|
      data = JSON.parse(pe[:data])
      assert_equal "2.0",                     data["jsonrpc"]
      assert_equal "notifications/progress",  data["method"]
      assert data["params"].key?("progressToken")
      assert data["params"].key?("progress")
      assert data["params"].key?("total")
      # progress field must be a number
      assert_kind_of Numeric, data.dig("params", "progress")
    end
  end

  # ---------------------------------------------------------------------------
  # 12. MCPRackApp constructor — streaming keyword accepted without error
  # ---------------------------------------------------------------------------

  def test_constructor_accepts_streaming_keyword
    assert_silent do
      Parse::Agent::MCPRackApp.new(
        agent_factory:      permissive_factory,
        streaming:          true,
        heartbeat_interval: 1,
      )
    end
  end

  def test_constructor_streaming_defaults_to_false
    # When streaming is false (default), SSE Accept does NOT trigger SSE path
    app = plain_app
    _status, headers, body = app.call(rack_env(accept: "text/event-stream"))
    drain_body(body) rescue nil
    assert_equal "application/json", headers["Content-Type"]
  end
end
