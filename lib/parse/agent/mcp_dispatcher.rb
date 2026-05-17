# encoding: UTF-8
# frozen_string_literal: true

require "json"
require_relative "errors"
require_relative "prompts"

module Parse
  class Agent
    # Pure JSON-RPC dispatch layer for the MCP protocol.
    #
    # MCPDispatcher translates an already-parsed JSON-RPC request body into a
    # JSON-RPC response envelope without touching any I/O, HTTP transport, or
    # authentication. Callers are responsible for:
    #   - Parsing the raw request body into a Hash.
    #   - Authenticating the request and constructing a Parse::Agent instance.
    #   - Serializing the returned Hash back to JSON and writing it to the wire.
    #
    # This design lets the same dispatch logic serve WEBrick (MCPServer),
    # Rack (MCPRackApp), and in-process tests without duplication.
    #
    # @example Basic usage
    #   body  = JSON.parse(raw_request_body)
    #   agent = Parse::Agent.new(permissions: :readonly)
    #   result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)
    #   # => { status: 200, body: { "jsonrpc" => "2.0", "id" => 1, "result" => {...} } }
    #
    module MCPDispatcher
      # MCP protocol version. Matches MCPServer::PROTOCOL_VERSION.
      PROTOCOL_VERSION = "2024-11-05"

      # Server capability advertisement (mirrors MCPServer::CAPABILITIES).
      CAPABILITIES = {
        "tools"     => { "listChanged" => false },
        "resources" => { "subscribe" => false, "listChanged" => false },
        "prompts"   => { "listChanged" => false },
      }.freeze

      # Parse class-name identifier regex — used to validate resource URIs.
      # Matches Parse's class-name convention: letter/underscore start, up to 128
      # chars, alphanumeric/underscore body.
      IDENTIFIER_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze

      # Maximum serialized response body for a single tools/call. Prevents a
      # wide-schema query with limit=1000 from producing tens of megabytes
      # of JSON before the response is written. When exceeded, the dispatcher
      # returns an isError tool result instructing the client to narrow the
      # query, NOT a JSON-RPC transport error.
      MAX_TOOL_RESPONSE_BYTES = 4_194_304  # 4 MiB

      # Dispatch a JSON-RPC request body to the appropriate handler.
      #
      # @param body [Hash] already-parsed JSON-RPC request body with string keys.
      #   Expected shape: { "jsonrpc" => "2.0", "method" => String,
      #                     "params"  => Hash,   "id"     => Any }
      # @param agent [Parse::Agent] an authenticated agent instance.
      # @return [Hash] always `{ status: Integer, body: Hash }`.
      #   `status` is the HTTP status code (200 for all successful dispatches,
      #   including JSON-RPC `error` responses; 401 only for Unauthorized).
      #   `body` is the full JSON-RPC response envelope (string keys) containing
      #   `"jsonrpc"`, `"id"`, and either `"result"` or `"error"`.
      #
      # @raise nothing — all exceptions are caught and translated to error envelopes.
      #
      # Error codes used:
      #   -32700  Parse error        (body is not a Hash or missing "method")
      #   -32601  Method not found   (unknown method name)
      #   -32602  Invalid params     (bad arguments, SecurityError, ValidationError)
      #   -32603  Internal error     (unexpected StandardError — class name only, no message)
      #   -32001  Unauthorized       (Parse::Agent::Unauthorized) → HTTP 401
      #
      # @note Parse::Agent::Prompts contract observed from prompts.rb:
      #   `Prompts.list` returns an Array of prompt descriptor Hashes (builtins
      #   merged with any registered custom prompts).
      #   `Prompts.render(name, args)` returns the full MCP envelope Hash
      #   `{ "description" => String, "messages" => [...] }` — already shaped.
      #   It raises `Parse::Agent::ValidationError` for unknown prompt names and
      #   for missing/invalid required arguments. The dispatcher passes the
      #   envelope through as-is and lets rescue handle ValidationError → -32602.
      # @param logger [#warn, nil] optional logger for internal errors. When
      #   not provided, falls back to `Kernel#warn` → $stderr. Wire from the
      #   transport layer (MCPRackApp forwards its logger here automatically).
      # @param progress_callback [Proc, nil] reserved for future tool-internal
      #   progress reporting (v4.2+). In v4.1 the dispatcher does not invoke
      #   this callback; periodic heartbeats are emitted by the Rack transport
      #   layer instead. The parameter is accepted so the API is stable across
      #   the v4.1 → v4.2 boundary.
      def self.call(body:, agent:, logger: nil, progress_callback: nil)
        # Guard: body must be a Hash with a "method" key.
        unless body.is_a?(Hash) && body.key?("method")
          id = body.is_a?(Hash) ? body["id"] : nil
          return { status: 200, body: jsonrpc_error(id, -32700, "Invalid Request") }
        end

        method = body["method"]
        params = body["params"] || {}
        id     = body["id"]

        result_hash = dispatch(method, params, agent, id, logger)
        { status: result_hash[:status], body: result_hash[:body] }

      rescue Parse::Agent::Unauthorized => e
        { status: 401, body: jsonrpc_error(body.is_a?(Hash) ? body["id"] : nil, -32001, "Unauthorized") }
      rescue StandardError => e
        # Do not leak the exception class name (gem fingerprinting). Server-
        # side log goes to the injected logger when set, otherwise $stderr.
        log_internal_error(logger, e)
        { status: 200, body: jsonrpc_error(body.is_a?(Hash) ? body["id"] : nil, -32603, "Internal error") }
      end

      # Emit an internal-error diagnostic. The class+message are operator-only;
      # never reach the wire.
      def self.log_internal_error(logger, error)
        line = "[Parse::Agent::MCPDispatcher] #{error.class}: #{error.message}"
        if logger
          logger.warn(line)
        else
          warn line
        end
      end
      private_class_method :log_internal_error

      # ---------------------------------------------------------------------------
      # Private helpers
      # ---------------------------------------------------------------------------

      # Route the method string to its handler, wrap the result in a JSON-RPC
      # envelope, and return { status:, body: }.
      #
      # @api private
      def self.dispatch(method, params, agent, id, logger = nil)
        result = case method
          when "initialize"
            handle_initialize(params)
          when "tools/list"
            handle_tools_list(params, agent)
          when "tools/call"
            handle_tools_call(params, agent)
          when "resources/list"
            handle_resources_list(params, agent)
          when "resources/read"
            handle_resources_read(params, agent)
          when "prompts/list"
            handle_prompts_list(params)
          when "prompts/get"
            handle_prompts_get(params)
          when "ping"
            {}
          else
            return { status: 200, body: jsonrpc_error(id, -32601, "Method not found: #{method}") }
          end

        # result is a Hash; if it carries an :error or "error" key the handler
        # wants a JSON-RPC error envelope, otherwise it's a result.
        err = result[:error] || result["error"]
        if err
          { status: 200, body: jsonrpc_envelope(id, error: err) }
        else
          { status: 200, body: jsonrpc_envelope(id, result: result) }
        end

      rescue Parse::Agent::Unauthorized => e
        { status: 401, body: jsonrpc_error(id, -32001, "Unauthorized") }
      rescue Parse::Agent::SecurityError
        { status: 200, body: jsonrpc_error(id, -32602, "Invalid params") }
      rescue Parse::Agent::ValidationError => e
        { status: 200, body: jsonrpc_error(id, -32602, e.message) }
      rescue ArgumentError => e
        # ArgumentError from prompts/render (matches current handle_prompts_get behavior).
        { status: 200, body: jsonrpc_error(id, -32602, e.message) }
      rescue StandardError => e
        log_internal_error(logger, e)
        { status: 200, body: jsonrpc_error(id, -32603, "Internal error") }
      end
      private_class_method :dispatch

      # ---------------------------------------------------------------------------
      # Handlers — each returns a plain Hash that becomes the JSON-RPC `result`.
      # If the handler needs to signal a protocol-level error it returns a Hash
      # with an :error key (same convention as mcp_server.rb).
      # ---------------------------------------------------------------------------

      # Handle the `initialize` MCP handshake.
      #
      # @return [Hash] protocol version, capabilities, and server info.
      def self.handle_initialize(_params)
        {
          "protocolVersion" => PROTOCOL_VERSION,
          "capabilities"    => CAPABILITIES,
          "serverInfo"      => {
            "name"    => "parse-stack-mcp",
            "version" => Parse::Stack::VERSION,
          },
        }
      end
      private_class_method :handle_initialize

      # Handle `tools/list`.
      #
      # @param agent [Parse::Agent] used to retrieve allowed tool definitions.
      # @return [Hash] `{ "tools" => [...] }`
      def self.handle_tools_list(_params, agent)
        { "tools" => agent.tool_definitions(format: :mcp) }
      end
      private_class_method :handle_tools_list

      # Handle `tools/call`.
      #
      # Tool execution failures (agent returns `success: false`) are returned as
      # MCP tool errors (`isError: true` in content) — NOT as a JSON-RPC `error`
      # field. This matches the MCP spec distinction between protocol errors and
      # tool-level errors.
      #
      # @param agent [Parse::Agent] used to execute the named tool.
      # @return [Hash] MCP content envelope (always a `result`, never `error`).
      def self.handle_tools_call(params, agent)
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        unless tool_name
          return { error: { "code" => -32602, "message" => "Missing tool name" } }
        end

        sym_args = arguments.transform_keys(&:to_sym)
        result   = agent.execute(tool_name.to_sym, **sym_args)

        if result[:success]
          text = JSON.pretty_generate(result[:data])
          if text.bytesize > MAX_TOOL_RESPONSE_BYTES
            # Refuse oversized tool results structurally — give the LLM
            # client a clear signal to narrow the request instead of silently
            # buffering tens of MB. isError: true (not a JSON-RPC error) so
            # the model can adapt mid-loop.
            {
              "content" => [
                { "type" => "text", "text" => "Tool result exceeded #{MAX_TOOL_RESPONSE_BYTES} bytes (#{text.bytesize}). Narrow the query: lower limit:, project fewer fields via keys:/select:, or add stricter where: constraints." },
              ],
              "isError" => true,
            }
          else
            {
              "content" => [
                { "type" => "text", "text" => text },
              ],
              "isError" => false,
            }
          end
        else
          {
            "content" => [
              { "type" => "text", "text" => result[:error].to_s },
            ],
            "isError" => true,
          }
        end
      end
      private_class_method :handle_tools_call

      # Handle `resources/list`.
      #
      # Exposes three virtual resources per Parse class: schema, count, and
      # samples. Falls back to an empty list if the agent cannot fetch schemas.
      #
      # @param agent [Parse::Agent]
      # @return [Hash] `{ "resources" => [...] }`
      def self.handle_resources_list(_params, agent)
        result = agent.execute(:get_all_schemas)
        return { "resources" => [] } unless result[:success]

        classes   = result[:data][:classes] || []
        resources = classes.flat_map do |cls|
          name       = cls[:name]
          klass_desc = cls[:description] || "Parse class (#{cls[:type] || "Custom"})"
          [
            {
              "uri"         => "parse://#{name}/schema",
              "name"        => "#{name} schema",
              "description" => "Field definitions and types for #{name}. #{klass_desc}",
              "mimeType"    => "application/json",
            },
            {
              "uri"         => "parse://#{name}/count",
              "name"        => "#{name} count",
              "description" => "Total number of #{name} objects",
              "mimeType"    => "application/json",
            },
            {
              "uri"         => "parse://#{name}/samples",
              "name"        => "#{name} samples",
              "description" => "Five most recent #{name} objects",
              "mimeType"    => "application/json",
            },
          ]
        end
        { "resources" => resources }
      end
      private_class_method :handle_resources_list

      # Handle `resources/read`.
      #
      # URI format: `parse://<ClassName>/<kind>` where kind is one of
      # `schema`, `count`, `samples`. The class name must match Parse's
      # identifier shape. Defaults to `schema` when kind is omitted.
      #
      # @param agent [Parse::Agent]
      # @return [Hash] MCP contents envelope or an error hash.
      def self.handle_resources_read(params, agent)
        uri   = params["uri"].to_s
        match = uri.match(%r{\Aparse://([A-Za-z_][A-Za-z0-9_]*)(?:/(schema|count|samples))?\z})
        return { error: { "code" => -32602, "message" => "Invalid resource URI: #{uri}" } } unless match

        class_name = match[1]
        kind       = match[2] || "schema"

        result = case kind
          when "schema"
            agent.execute(:get_schema, class_name: class_name)
          when "count"
            agent.execute(:count_objects, class_name: class_name)
          when "samples"
            agent.execute(:get_sample_objects, class_name: class_name, limit: 5)
          end

        if result[:success]
          {
            "contents" => [
              {
                "uri"      => uri,
                "mimeType" => "application/json",
                "text"     => JSON.pretty_generate(result[:data]),
              },
            ],
          }
        else
          { error: { "code" => -32603, "message" => result[:error].to_s } }
        end
      end
      private_class_method :handle_resources_read

      # Handle `prompts/list`.
      #
      # Delegates to `Parse::Agent::Prompts.list`, which returns an Array of
      # prompt descriptor Hashes. The dispatcher wraps the array into the MCP
      # envelope `{ "prompts" => [...] }`.
      #
      # @return [Hash] `{ "prompts" => [...] }`
      def self.handle_prompts_list(_params)
        { "prompts" => Parse::Agent::Prompts.list }
      end
      private_class_method :handle_prompts_list

      # Handle `prompts/get`.
      #
      # Fully delegates to `Parse::Agent::Prompts.render(name, args)`, which
      # returns the complete MCP messages envelope:
      #   { "description" => String, "messages" => [{ "role" => "user", ... }] }
      #
      # `Prompts.render` raises `Parse::Agent::ValidationError` for unknown
      # prompt names or missing/invalid required arguments. The `dispatch`
      # rescue clause converts those into JSON-RPC -32602 responses so the
      # message text (including "Unknown prompt: <name>") reaches the caller.
      #
      # @return [Hash] MCP messages envelope (already shaped by Prompts.render).
      def self.handle_prompts_get(params)
        name = params["name"].to_s
        args = params["arguments"] || {}
        Parse::Agent::Prompts.render(name, args)
      end
      private_class_method :handle_prompts_get

      # ---------------------------------------------------------------------------
      # Envelope helpers
      # ---------------------------------------------------------------------------

      # Build a complete JSON-RPC response envelope with string keys.
      #
      # @param id [Any] the JSON-RPC request id (may be nil for notifications).
      # @param result [Hash, nil] the result payload (mutually exclusive with error).
      # @param error  [Hash, nil] the error payload (mutually exclusive with result).
      # @return [Hash] JSON-RPC envelope with string keys.
      def self.jsonrpc_envelope(id, result: nil, error: nil)
        envelope = { "jsonrpc" => "2.0", "id" => id }
        if error
          envelope["error"] = error
        else
          envelope["result"] = result || {}
        end
        envelope
      end
      private_class_method :jsonrpc_envelope

      # Build a JSON-RPC error envelope.
      #
      # @param id      [Any]     the request id.
      # @param code    [Integer] JSON-RPC error code.
      # @param message [String]  human-readable error message (must NOT include
      #   raw query content, user data, or internal stack information).
      # @return [Hash] JSON-RPC error envelope with string keys.
      def self.jsonrpc_error(id, code, message)
        jsonrpc_envelope(id, error: { "code" => code, "message" => message })
      end
      private_class_method :jsonrpc_error
    end
  end
end
