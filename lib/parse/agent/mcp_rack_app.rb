# encoding: UTF-8
# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "errors"
require_relative "mcp_dispatcher"

module Parse
  class Agent
    # Rack adapter that exposes Parse::Agent::MCPDispatcher as a mountable
    # Rack endpoint. Downstream applications can mount this inside Sinatra,
    # Rails, or any Rack-compatible router at an arbitrary path and behind
    # their own authentication gate.
    #
    # The adapter enforces the same transport-level invariants as MCPServer
    # (method, content-type, body-size, and JSON-parse checks) and then
    # delegates to Parse::Agent::MCPDispatcher.call for all protocol handling.
    #
    # == SSE Streaming (MCP progress notifications)
    #
    # When constructed with `streaming: true`, requests that include
    # `Accept: text/event-stream` receive an SSE response instead of a single
    # JSON body. The server holds the connection open and emits periodic
    # `notifications/progress` heartbeats (every `heartbeat_interval` seconds)
    # while the dispatcher executes the tool call. A final `response` event
    # carries the complete JSON-RPC response, after which the stream closes.
    #
    # This lets LLM clients observe progress on long-running tool calls (such
    # as aggregate pipelines) rather than timing out silently.
    #
    # Streaming requires a Rack server that supports streaming response bodies
    # (Puma, Falcon, Unicorn). WEBrick buffers the full body before writing,
    # so SSE streaming has no effect on the standalone MCPServer — operators
    # using MCPServer directly should leave `streaming: false` (the default).
    #
    # To disable Nginx response buffering for SSE endpoints, set:
    #   proxy_buffering off;
    # or rely on the `X-Accel-Buffering: no` header this class emits
    # automatically on every SSE response.
    #
    # When `streaming: false` (default), an `Accept: text/event-stream` request
    # receives a plain JSON response — the adapter is permissive per the MCP
    # spec, which does not require SSE support.
    #
    # @example Block form (most common)
    #   app = Parse::Agent::MCPRackApp.new do |env|
    #     token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ")
    #     agent = MyAuth.agent_for_token!(token)  # raises Unauthorized if invalid
    #     agent
    #   end
    #
    # @example Keyword argument form
    #   factory = ->(env) { Parse::Agent.new(permissions: :readonly) }
    #   app = Parse::Agent::MCPRackApp.new(agent_factory: factory)
    #
    # @example With SSE streaming enabled
    #   app = Parse::Agent::MCPRackApp.new(streaming: true) { |env| ... }
    #
    # @example Mounted in Rails routes.rb
    #   mount Parse::Agent::MCPRackApp.new { |env| ... }, at: "/mcp"
    #
    class MCPRackApp
      # Maximum allowed request body size in bytes (matches MCPServer::MAX_BODY_SIZE).
      DEFAULT_MAX_BODY_SIZE = 1_048_576  # 1 MB

      # JSON nesting depth limit (matches MCPServer::MAX_JSON_NESTING).
      MAX_JSON_NESTING = 20

      # Default heartbeat interval in seconds when streaming is enabled.
      DEFAULT_HEARTBEAT_INTERVAL = 2

      # Standard Content-Type for all JSON responses.
      JSON_CONTENT_TYPE = { "Content-Type" => "application/json" }.freeze

      # SSE response headers. X-Accel-Buffering disables Nginx proxy buffering.
      SSE_HEADERS = {
        "Content-Type"      => "text/event-stream",
        "Cache-Control"     => "no-cache",
        "Connection"        => "keep-alive",
        "X-Accel-Buffering" => "no",
      }.freeze

      # @param agent_factory [Proc, nil] callable invoked with the Rack env on
      #   every request. Must return a Parse::Agent or raise
      #   Parse::Agent::Unauthorized. Mutually exclusive with a block.
      # @param max_body_size [Integer] reject bodies larger than this many bytes.
      #   Defaults to DEFAULT_MAX_BODY_SIZE.
      # @param logger [#warn, nil] optional logger. When set, auth failures are
      #   warned at class-name level, and internal errors include a backtrace.
      # @param streaming [Boolean] enable SSE streaming for clients that send
      #   `Accept: text/event-stream`. Defaults to false for backward
      #   compatibility. Has no effect on WEBrick-backed deployments (see
      #   class documentation).
      # @param heartbeat_interval [Numeric] seconds between progress heartbeat
      #   events when streaming is active. Defaults to DEFAULT_HEARTBEAT_INTERVAL.
      #   Ignored when `streaming: false`.
      # @raise [ArgumentError] if both or neither of agent_factory/block are given.
      def initialize(agent_factory: nil, max_body_size: DEFAULT_MAX_BODY_SIZE,
                     logger: nil, streaming: false,
                     heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL, &block)
        if agent_factory && block
          raise ArgumentError, "Provide agent_factory: OR a block, not both"
        end
        unless agent_factory || block
          raise ArgumentError, "Either agent_factory: keyword or a block is required"
        end

        @agent_factory       = agent_factory || block
        @max_body_size       = max_body_size
        @logger              = logger
        @streaming           = streaming
        @heartbeat_interval  = heartbeat_interval
      end

      # Rack interface.
      #
      # @param env [Hash] Rack environment
      # @return [Array(Integer, Hash, #each)] Rack triple
      def call(env)
        # 1. Method check — only POST is accepted.
        unless env["REQUEST_METHOD"] == "POST"
          return [405,
                  JSON_CONTENT_TYPE.merge("Allow" => "POST"),
                  [json_rpc_error(-32_700, "method_not_allowed")]]
        end

        # 2. Content-type check — must be application/json (charset ignored).
        content_type = env["CONTENT_TYPE"].to_s.split(";").first.to_s.strip.downcase
        unless content_type == "application/json"
          return [415, JSON_CONTENT_TYPE, [json_rpc_error(-32_700, "Unsupported Media Type: Content-Type must be application/json")]]
        end

        # 3. Body size limit — read one byte beyond limit to detect oversized bodies
        #    without buffering the full stream.
        raw_body = env["rack.input"].read(@max_body_size + 1)
        if raw_body.bytesize > @max_body_size
          return [413, JSON_CONTENT_TYPE, [json_rpc_error(-32_700, "Payload Too Large: body exceeds #{@max_body_size} bytes")]]
        end

        # 4. JSON parse.
        begin
          body = JSON.parse(raw_body.empty? ? "{}" : raw_body, max_nesting: MAX_JSON_NESTING)
        rescue JSON::ParserError, JSON::NestingError
          return [400, JSON_CONTENT_TYPE, [json_rpc_error(-32_700, "Parse error: invalid JSON")]]
        end

        # 5. Agent factory — auth gate. Rescue Unauthorized first, then catch-all
        #    for unexpected factory errors.
        begin
          agent = @agent_factory.call(env)
        rescue Parse::Agent::Unauthorized => e
          @logger.warn("[Parse::Agent::MCPRackApp] Unauthorized: #{e.class.name}") if @logger
          return [401, JSON_CONTENT_TYPE, [unauthorized_body]]
        rescue StandardError => e
          if @logger
            @logger.warn("[Parse::Agent::MCPRackApp] Factory error: #{e.class.name}")
            @logger.warn(e.backtrace.join("\n")) if e.backtrace
          end
          return [500, JSON_CONTENT_TYPE, [json_rpc_error(-32_603, "Internal error")]]
        end

        # 6. Branch on streaming preference. Transport-level errors (steps 1-5)
        #    always return plain JSON regardless of the Accept header.
        if @streaming && env["HTTP_ACCEPT"].to_s.include?("text/event-stream")
          serve_sse(body, agent)
        else
          serve_json(body, agent)
        end
      end

      private

      # ---------------------------------------------------------------------------
      # Response paths
      # ---------------------------------------------------------------------------

      # Dispatch synchronously and return a single JSON Rack response.
      #
      # @param body  [Hash] parsed JSON-RPC request body.
      # @param agent [Parse::Agent] authenticated agent.
      # @return [Array] Rack triple with Array<String> body.
      def serve_json(body, agent)
        result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent, logger: @logger)
        [result[:status], JSON_CONTENT_TYPE, [JSON.generate(result[:body])]]
      end

      # Return a streaming Rack response that emits SSE progress events while
      # the dispatcher runs, followed by a final `response` event.
      #
      # The response body is an SSEBody instance whose `#each` method blocks
      # (reading from an internal Queue) until the worker thread signals
      # completion. All `yield` calls happen on the thread/fiber that drives
      # `#each` (the Rack server's I/O thread); the worker thread only pushes
      # to the Queue, avoiding Fiber cross-thread violations.
      #
      # @param body  [Hash] parsed JSON-RPC request body.
      # @param agent [Parse::Agent] authenticated agent.
      # @return [Array] Rack triple with SSEBody as the body.
      def serve_sse(body, agent)
        progress_token = body.dig("params", "_meta", "progressToken") || SecureRandom.uuid
        req_id         = body["id"]
        interval       = @heartbeat_interval
        logger         = @logger

        sse_body = SSEBody.new(progress_token, req_id, interval, logger) do
          Parse::Agent::MCPDispatcher.call(body: body, agent: agent, logger: logger)
        end

        [200, SSE_HEADERS, sse_body]
      end

      # ---------------------------------------------------------------------------
      # SSE body class
      # ---------------------------------------------------------------------------

      # Rack body object that emits MCP progress notifications over SSE.
      #
      # `#each` is the only public interface (besides `#close`). It is driven
      # by the Rack server on whatever thread/fiber handles response writing.
      # The dispatcher call and heartbeat timer both run on a dedicated worker
      # thread so they do not block the calling fiber.
      #
      # Wire format for each SSE event (note: trailing blank line is required
      # by the SSE spec):
      #
      #   event: progress\n
      #   data: <json>\n
      #   \n
      #
      # @api private
      class SSEBody
        # Sentinel pushed to the queue when the worker is done.
        DONE = :__sse_done__

        # @param progress_token [String] MCP progressToken value.
        # @param req_id         [Object] JSON-RPC request id (may be nil).
        # @param interval       [Numeric] heartbeat period in seconds.
        # @param logger         [#warn, nil] optional logger.
        # @param dispatcher_blk [Proc] called with no args; must return the
        #   same `{ status:, body: }` hash that MCPDispatcher.call returns.
        def initialize(progress_token, req_id, interval, logger, &dispatcher_blk)
          @progress_token = progress_token
          @req_id         = req_id
          @interval       = interval
          @logger         = logger
          @dispatcher_blk = dispatcher_blk
          @queue          = Queue.new
          @worker         = nil
        end

        # Rack body interface — called once by the Rack server.
        #
        # Starts a worker thread that runs the dispatcher and emits periodic
        # heartbeats via the queue, then loops reading from the queue and
        # yielding formatted SSE strings until the final response is sent.
        #
        # @yield [String] SSE-formatted event strings.
        def each
          start_worker
          loop do
            msg = @queue.pop
            break if msg == DONE
            yield msg
          end
        ensure
          close
        end

        # Terminate the worker thread if it is still alive (e.g. the client
        # disconnected before the stream ended).
        def close
          @worker&.kill if @worker&.alive?
          @worker = nil
        end

        private

        def start_worker
          @worker = Thread.new do
            started_at = Time.now
            result     = nil

            # Run the dispatcher in the background. Meanwhile emit heartbeats
            # every @interval seconds until the call completes.
            #
            # NOTE (v4.2): If the consumer disconnects (close is called), the
            # outer @worker is killed but dispatcher_thread is orphaned and
            # runs to completion. A proper cancellation mechanism (e.g. passing
            # a cancel token into MCPDispatcher) is deferred to v4.2.
            dispatcher_thread = Thread.new do
              begin
                result = @dispatcher_blk.call
              rescue => e
                result = { status: 200, body: build_error_envelope(e) }
              end
            end

            while dispatcher_thread.alive?
              dispatcher_thread.join(@interval)
              if dispatcher_thread.alive?
                elapsed = (Time.now - started_at).round(1)
                @queue << build_progress_event(elapsed)
              end
            end

            # Final response event followed by the done sentinel.
            @queue << build_response_event(result[:body])
            @queue << DONE
          rescue => e
            # Worker-level safety net — ensure the stream always closes.
            line = "[Parse::Agent::MCPRackApp::SSEBody] Worker error: #{e.class}: #{e.message}"
            if @logger
              @logger.warn(line)
            else
              warn line
            end
            @queue << build_response_event(build_error_envelope(e))
            @queue << DONE
          end
        end

        # Format a `notifications/progress` SSE event.
        #
        # @param elapsed [Float] seconds elapsed since the stream started.
        # @return [String] SSE event string (includes trailing blank line).
        def build_progress_event(elapsed)
          data = JSON.generate({
            "jsonrpc" => "2.0",
            "method"  => "notifications/progress",
            "params"  => {
              "progressToken" => @progress_token,
              "progress"      => elapsed,
              "total"         => nil,
            },
          })
          "event: progress\ndata: #{data}\n\n"
        end

        # Format the final `response` SSE event.
        #
        # @param body [Hash] JSON-RPC response envelope.
        # @return [String] SSE event string (includes trailing blank line).
        def build_response_event(body)
          "event: response\ndata: #{JSON.generate(body)}\n\n"
        end

        # Build an internal-error JSON-RPC envelope (id may be nil at this layer).
        def build_error_envelope(error)
          {
            "jsonrpc" => "2.0",
            "id"      => @req_id,
            "error"   => { "code" => -32_603, "message" => "Internal error" },
          }
        end
      end

      # ---------------------------------------------------------------------------
      # JSON-RPC envelope helpers
      # ---------------------------------------------------------------------------

      # Build a sanitized JSON-RPC 2.0 error envelope.
      # The id is always null at transport level because we may not have parsed
      # the body successfully.
      def json_rpc_error(code, message)
        JSON.generate({
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => { "code" => code, "message" => message },
        })
      end

      # Fixed 401 body — no exception details leak to the caller.
      def unauthorized_body
        JSON.generate({
          "jsonrpc" => "2.0",
          "id" => nil,
          "error" => { "code" => -32_001, "message" => "Unauthorized" },
        })
      end
    end
  end
end
