# encoding: UTF-8
# frozen_string_literal: true

require "webrick"
require "json"
require "active_support/core_ext/object/blank"
require "active_support/security_utils"

module Parse
  class Agent
    # MCP (Model Context Protocol) HTTP Server for Parse Stack.
    # Enables external AI agents (Claude, LM Studio, etc.) to interact with
    # Parse data over HTTP using the MCP protocol specification.
    #
    # @example Start the server
    #   Parse::Agent.enable_mcp!
    #   Parse::Agent::MCPServer.run(port: 3001)
    #
    # @example With custom configuration
    #   server = Parse::Agent::MCPServer.new(
    #     port: 3001,
    #     permissions: :readonly,
    #     session_token: nil
    #   )
    #   server.start
    #
    # @see https://modelcontextprotocol.io/ MCP Protocol Specification
    #
    class MCPServer
      # MCP Protocol version
      PROTOCOL_VERSION = "2024-11-05"

      # Server capabilities
      CAPABILITIES = {
        tools: { listChanged: false },
        resources: { subscribe: false, listChanged: false },
        prompts: { listChanged: false },
      }.freeze

      # Default port for the MCP server
      @default_port = 3001

      # Maximum allowed request body size (1 MB)
      MAX_BODY_SIZE = 1_048_576

      # Maximum JSON nesting depth
      MAX_JSON_NESTING = 20

      # HTTP header for MCP API key authentication
      MCP_API_KEY_HEADER = "X-MCP-API-Key"

      class << self
        attr_accessor :default_port

        # Start the MCP server (blocking)
        #
        # @param port [Integer] port to listen on
        # @param permissions [Symbol] agent permission level
        # @param session_token [String, nil] optional session token
        # @param host [String] host to bind to
        def run(port: nil, permissions: :readonly, session_token: nil, host: "127.0.0.1", api_key: nil)
          unless Parse::Agent.mcp_enabled?
            raise "MCP server not enabled. Call Parse::Agent.enable_mcp! first"
          end

          server = new(
            port: port || @default_port,
            permissions: permissions,
            session_token: session_token,
            host: host,
            api_key: api_key,
          )
          server.start
        end
      end

      # @return [Integer] the port number
      attr_reader :port

      # @return [String] the host to bind to
      attr_reader :host

      # @return [Parse::Agent] the agent instance
      attr_reader :agent

      # Create a new MCP server instance
      #
      # @param port [Integer] port to listen on
      # @param host [String] host to bind to
      # @param permissions [Symbol] agent permission level
      # @param session_token [String, nil] optional session token
      def initialize(port: 3001, host: "127.0.0.1", permissions: :readonly, session_token: nil, api_key: nil)
        @port = port
        @host = host
        @api_key = api_key || ENV["MCP_API_KEY"]
        @agent = Parse::Agent.new(permissions: permissions, session_token: session_token)
        @server = nil
      end

      # Start the HTTP server (blocking)
      def start
        @server = WEBrick::HTTPServer.new(
          Port: @port,
          BindAddress: @host,
          Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO),
          AccessLog: [[::File.open(::File::NULL, "w"), ""]], # Suppress access log
        )

        setup_routes

        trap("INT") { stop }
        trap("TERM") { stop }

        puts "Parse MCP Server starting on http://#{@host}:#{@port}"
        puts "Permissions: #{@agent.permissions}"
        puts "Tools available: #{@agent.allowed_tools.join(", ")}"

        @server.start
      end

      # Stop the server
      def stop
        @server&.shutdown
      end

      private

      def setup_routes
        # MCP endpoint for all protocol messages
        @server.mount_proc("/mcp") { |req, res| handle_mcp_request(req, res) }

        # Health check endpoint (unauthenticated - standard for monitoring)
        @server.mount_proc("/health") do |_req, res|
          json_response(res, { status: "ok", mcp_enabled: true })
        end

        # Tool list endpoint (requires auth if API key is configured)
        @server.mount_proc("/tools") do |req, res|
          if @api_key.present?
            provided_key = req[MCP_API_KEY_HEADER].to_s
            unless ActiveSupport::SecurityUtils.secure_compare(@api_key, provided_key)
              error_response(res, 401, "Unauthorized: invalid or missing API key")
              next
            end
          end
          json_response(res, @agent.tool_definitions(format: :mcp))
        end
      end

      # Handle MCP protocol requests
      def handle_mcp_request(req, res)
        unless req.request_method == "POST"
          return error_response(res, 405, "Method not allowed")
        end

        # C4: API key authentication
        if @api_key.present?
          provided_key = req[MCP_API_KEY_HEADER].to_s
          unless ActiveSupport::SecurityUtils.secure_compare(@api_key, provided_key)
            return error_response(res, 401, "Unauthorized: invalid or missing API key")
          end
        end

        # C5: Payload size limit
        raw_body = req.body || "{}"
        if raw_body.bytesize > MAX_BODY_SIZE
          return error_response(res, 413, "Payload too large (max #{MAX_BODY_SIZE} bytes)")
        end

        begin
          body = JSON.parse(raw_body, max_nesting: MAX_JSON_NESTING)
        rescue JSON::ParserError, JSON::NestingError => e
          return error_response(res, 400, "Invalid JSON: #{e.message}")
        end

        method = body["method"]
        params = body["params"] || {}
        id = body["id"]

        result = case method
          when "initialize"
            handle_initialize(params)
          when "tools/list"
            handle_tools_list(params)
          when "tools/call"
            handle_tools_call(params)
          when "resources/list"
            handle_resources_list(params)
          when "resources/read"
            handle_resources_read(params)
          when "prompts/list"
            handle_prompts_list(params)
          when "prompts/get"
            handle_prompts_get(params)
          when "ping"
            {}
          else
            { error: { code: -32601, message: "Method not found: #{method}" } }
          end

        response = {
          jsonrpc: "2.0",
          id: id,
        }

        if result[:error]
          response[:error] = result[:error]
        else
          response[:result] = result
        end

        json_response(res, response)
      end

      # Handle MCP initialize request
      def handle_initialize(_params)
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: CAPABILITIES,
          serverInfo: {
            name: "parse-stack-mcp",
            version: Parse::Stack::VERSION,
          },
        }
      end

      # Handle tools/list request
      def handle_tools_list(_params)
        {
          tools: @agent.tool_definitions(format: :mcp),
        }
      end

      # Handle tools/call request
      def handle_tools_call(params)
        tool_name = params["name"]
        arguments = params["arguments"] || {}

        unless tool_name
          return { error: { code: -32602, message: "Missing tool name" } }
        end

        # Convert string keys to symbols for Ruby
        sym_args = arguments.transform_keys(&:to_sym)

        result = @agent.execute(tool_name.to_sym, **sym_args)

        if result[:success]
          {
            content: [
              {
                type: "text",
                text: JSON.pretty_generate(result[:data]),
              },
            ],
            isError: false,
          }
        else
          {
            content: [
              {
                type: "text",
                text: result[:error],
              },
            ],
            isError: true,
          }
        end
      end

      # Handle resources/list request. Exposes three resources per Parse class —
      # schema, count, and a small sample — so a client can orient itself
      # without having to call tools first.
      def handle_resources_list(_params)
        result = @agent.execute(:get_all_schemas)
        return { resources: [] } unless result[:success]

        classes = result[:data][:classes] || []
        resources = classes.flat_map do |cls|
          name = cls[:name]
          klass_desc = cls[:description] || "Parse class (#{cls[:type] || "Custom"})"
          [
            {
              uri: "parse://#{name}/schema",
              name: "#{name} schema",
              description: "Field definitions and types for #{name}. #{klass_desc}",
              mimeType: "application/json",
            },
            {
              uri: "parse://#{name}/count",
              name: "#{name} count",
              description: "Total number of #{name} objects",
              mimeType: "application/json",
            },
            {
              uri: "parse://#{name}/samples",
              name: "#{name} samples",
              description: "Five most recent #{name} objects",
              mimeType: "application/json",
            },
          ]
        end
        { resources: resources }
      end

      # Handle resources/read request. URIs follow `parse://<ClassName>/<kind>`
      # where kind is one of `schema`, `count`, `samples`. The regex enforces
      # Parse's class-name shape (`[A-Za-z_][A-Za-z0-9_]*`) and whitelists the
      # kind so any unexpected input fails fast with a -32602.
      def handle_resources_read(params)
        uri = params["uri"].to_s
        match = uri.match(%r{\Aparse://([A-Za-z_][A-Za-z0-9_]*)(?:/(schema|count|samples))?\z})
        return { error: { code: -32602, message: "Invalid resource URI: #{uri}" } } unless match

        class_name = match[1]
        kind = match[2] || "schema"

        result = case kind
          when "schema"
            @agent.execute(:get_schema, class_name: class_name)
          when "count"
            @agent.execute(:count_objects, class_name: class_name)
          when "samples"
            @agent.execute(:get_sample_objects, class_name: class_name, limit: 5)
          end

        if result[:success]
          {
            contents: [
              {
                uri: uri,
                mimeType: "application/json",
                text: JSON.pretty_generate(result[:data]),
              },
            ],
          }
        else
          { error: { code: -32603, message: result[:error] } }
        end
      end

      # Handle prompts/list request. Returns analytics-oriented prompts aimed at
      # common superadmin questions ("how many users per team", "when was the
      # last project created", etc.). Use prompts/get to materialize one.
      def handle_prompts_list(_params)
        { prompts: STATIC_PROMPTS }
      end

      # Handle prompts/get request. Renders a prompt template into MCP messages.
      # `ArgumentError` from render_prompt's validators is converted into a
      # -32602 invalid-params response so the client sees why the call failed.
      def handle_prompts_get(params)
        name = params["name"].to_s
        args = params["arguments"] || {}

        begin
          text = render_prompt(name, args)
        rescue ArgumentError => e
          return { error: { code: -32602, message: e.message } }
        end
        return { error: { code: -32602, message: "Unknown prompt: #{name}" } } if text.nil?

        {
          description: "Parse analytics prompt: #{name}",
          messages: [
            {
              role: "user",
              content: { type: "text", text: text },
            },
          ],
        }
      end

      # Static prompt catalog. Each entry advertises which arguments a client
      # should supply; render_prompt below turns those into the actual message
      # body sent to the LLM.
      STATIC_PROMPTS = [
        {
          name: "parse_conventions",
          description: "Generic Parse platform conventions (objectId, createdAt, pointer/date shapes, _User, ACL). Fetch once and prepend to your system message.",
          arguments: [],
        },
        {
          name: "parse_relations",
          description: "Compact ASCII diagram of class relationships derived from belongs_to and has_many :through => :relation. Pass `classes` for a subset slice (both endpoints must be in the set).",
          arguments: [
            { name: "classes", description: "Optional comma-separated subset, e.g. \"_User,Post,Company\"", required: false },
          ],
        },
        {
          name: "explore_database",
          description: "Survey all Parse classes: list them, count each, and summarize what each appears to store",
          arguments: [],
        },
        {
          name: "class_overview",
          description: "Describe a class in detail: schema, total count, and a few sample objects",
          arguments: [
            { name: "class_name", description: "Parse class name", required: true },
          ],
        },
        {
          name: "count_by",
          description: "Count objects in a class grouped by a field (e.g. users by team, projects by status)",
          arguments: [
            { name: "class_name", description: "Parse class to count", required: true },
            { name: "group_by", description: "Field to group by", required: true },
          ],
        },
        {
          name: "recent_activity",
          description: "Show the most recently created objects in a class (answers \"when was the last X created\")",
          arguments: [
            { name: "class_name", description: "Parse class name", required: true },
            { name: "limit", description: "Number of objects to return (default 10)", required: false },
          ],
        },
        {
          name: "find_relationship",
          description: "Find objects in one class related to a given object in another (e.g. members of a team)",
          arguments: [
            { name: "parent_class", description: "Class of the parent object (e.g. Team)", required: true },
            { name: "parent_id", description: "objectId of the parent", required: true },
            { name: "child_class", description: "Class to query (e.g. _User)", required: true },
            { name: "pointer_field", description: "Field on child_class that points to parent (e.g. team)", required: true },
          ],
        },
        {
          name: "created_in_range",
          description: "Count and sample objects created within a date range",
          arguments: [
            { name: "class_name", description: "Parse class name", required: true },
            { name: "since", description: "ISO8601 lower bound (inclusive)", required: true },
            { name: "until", description: "ISO8601 upper bound (exclusive); omit for now", required: false },
          ],
        },
      ].freeze

      # Parse identifier shape (matches Parse class & field names).
      IDENTIFIER_RE = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/.freeze
      # Parse objectId shape — alphanumeric, typically 10-32 chars.
      OBJECT_ID_RE = /\A[A-Za-z0-9]{1,32}\z/.freeze

      # Render a prompt template to a single user-message string.
      # All caller-supplied arguments are validated against strict shapes before
      # being interpolated, so a malicious client cannot inject English
      # instructions or JSON fragments into the LLM context.
      # @raise [ArgumentError] if a required argument is missing or invalid.
      # @return [String, nil] the prompt text, or nil if `name` is unknown.
      def render_prompt(name, args)
        case name
        when "parse_conventions"
          Parse::Agent::PARSE_CONVENTIONS
        when "parse_relations"
          subset = args["classes"].to_s.split(",").map(&:strip).reject(&:empty?)
          subset.each { |c| validate_identifier!(c, "classes entry") }
          subset = nil if subset.empty?
          edges = Parse::Agent::RelationGraph.build(classes: subset)
          diagram = Parse::Agent::RelationGraph.to_ascii(edges)
          slice_note = subset ? " (subset: #{subset.join(", ")})" : ""
          # When an explicit subset returns no edges, the LLM otherwise
          # gets only "(no class relations defined)" with no indication
          # that the cause is likely a typo'd class name. Surface that.
          empty_subset_hint = (subset && edges.empty?) ?
            " No edges matched the requested subset — check the class names for casing and spelling (e.g. `_User`, not `_user`)." : ""
          "Class relationships in this Parse database#{slice_note}.#{empty_subset_hint} " \
          "Owning-field names are camelCase exactly as stored in Parse. " \
          "Read each line as: <one side> ─<cardinality>→ <many side> (owning field). " \
          "Use the owning field name with `query_class where:` to filter by that pointer, or with `include:` to expand it.\n\n#{diagram}"
        when "explore_database"
          "Survey the Parse database. Call get_all_schemas to list every class, then call count_objects on each to get totals. " \
          "Skip `_`-prefixed system classes other than `_User` and `_Role` (they may be empty, huge, or return errors). " \
          "Group remaining classes by likely purpose (users/auth, content, app-specific) and summarize what the database is for."
        when "class_overview"
          cn = validate_identifier!(args["class_name"], "class_name")
          "Describe the #{cn} class. Call get_schema for #{cn}, count_objects to get the total, and get_sample_objects (limit: 3). Summarize fields, what the class represents, and notable values in the samples."
        when "count_by"
          cn = validate_identifier!(args["class_name"], "class_name")
          gb = validate_identifier!(args["group_by"], "group_by")
          pipeline = [
            { "$group" => { "_id" => "$#{gb}", "count" => { "$sum" => 1 } } },
            { "$sort" => { "count" => -1 } },
            { "$limit" => 25 },
          ]
          "Count #{cn} objects grouped by #{gb}. Use aggregate with class_name=\"#{cn}\" and pipeline #{pipeline.to_json}. " \
          "If #{gb} is a pointer field, Parse returns each `_id` as the literal string \"ClassName$objectId\" (e.g. \"Team$abc123\") — strip the \"ClassName$\" prefix to recover the objectId, then optionally call get_object on a few to label them. " \
          "Report the top groups, call out any null/missing values, and give the total."
        when "recent_activity"
          cn = validate_identifier!(args["class_name"], "class_name")
          limit = (args["limit"] || 10).to_i
          limit = 10 if limit <= 0
          limit = 100 if limit > 100
          "Show the #{limit} most recently created #{cn} objects. Use query_class with class_name=\"#{cn}\", order=\"-createdAt\", limit=#{limit}. Report the createdAt of the latest one prominently and highlight notable fields."
        when "find_relationship"
          pc = validate_identifier!(args["parent_class"], "parent_class")
          pid = validate_object_id!(args["parent_id"], "parent_id")
          cc = validate_identifier!(args["child_class"], "child_class")
          pf = validate_identifier!(args["pointer_field"], "pointer_field")
          where = { pf => { "__type" => "Pointer", "className" => pc, "objectId" => pid } }
          "Find #{cc} objects whose #{pf} field points to #{pc} #{pid}. " \
          "First call count_objects with class_name=\"#{cc}\" and where=#{where.to_json}. " \
          "Then call query_class with the same constraint, limit 20, to show a sample. " \
          "Note: #{pf} must match the field name as stored (camelCase as defined in the schema). Report the count first."
        when "created_in_range"
          cn = validate_identifier!(args["class_name"], "class_name")
          since = validate_iso8601!(args["since"], "since")
          upper = validate_iso8601!(args["until"], "until", required: false)
          date_constraint = { "$gte" => { "__type" => "Date", "iso" => since } }
          date_constraint["$lt"] = { "__type" => "Date", "iso" => upper } if upper
          where = { "createdAt" => date_constraint }
          "Count #{cn} objects created since #{since}#{upper ? " and before #{upper}" : ""}. " \
          "Use count_objects with class_name=\"#{cn}\" and where=#{where.to_json}. " \
          "Then call query_class with the same where, order=\"-createdAt\", limit=10 for a sample. Report the count and the date range of the sample."
        end
      end

      def validate_identifier!(value, name)
        raise ArgumentError, "missing required argument: #{name}" if value.nil? || value.to_s.empty?
        s = value.to_s
        return s if s.match?(IDENTIFIER_RE)
        raise ArgumentError, "#{name} must match #{IDENTIFIER_RE.source} (got: #{s.inspect})"
      end

      def validate_object_id!(value, name)
        raise ArgumentError, "missing required argument: #{name}" if value.nil? || value.to_s.empty?
        s = value.to_s
        return s if s.match?(OBJECT_ID_RE)
        raise ArgumentError, "#{name} must be an alphanumeric objectId (got: #{s.inspect})"
      end

      def validate_iso8601!(value, name, required: true)
        if value.nil? || value.to_s.empty?
          return nil unless required
          raise ArgumentError, "missing required argument: #{name}"
        end
        require "time"
        Time.iso8601(value.to_s).utc.iso8601(3)
      rescue ArgumentError
        raise ArgumentError, "#{name} must be a valid ISO8601 timestamp (got: #{value.inspect})"
      end

      def json_response(res, data)
        res.content_type = "application/json"
        res.body = JSON.generate(data)
      end

      def error_response(res, status, message)
        res.status = status
        json_response(res, { error: message })
      end
    end
  end
end
