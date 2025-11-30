# encoding: UTF-8
# frozen_string_literal: true

require_relative "agent/metadata_dsl"
require_relative "agent/metadata_registry"
require_relative "agent/tools"
require_relative "agent/constraint_translator"
require_relative "agent/result_formatter"
require_relative "agent/pipeline_validator"
require_relative "agent/rate_limiter"

# Only load MCP server when explicitly enabled
# require_relative "agent/mcp_server"

module Parse
  # The Parse::Agent module provides AI/LLM integration capabilities for Parse Stack.
  # It enables AI agents to interact with Parse data through a standardized tool interface.
  #
  # The agent supports two operational modes:
  # - **Readonly mode**: Query, count, schema, and aggregation operations only
  # - **Write mode**: Full CRUD operations (requires explicit opt-in)
  #
  # @example Basic readonly agent usage
  #   agent = Parse::Agent.new
  #
  #   # Get all schemas
  #   result = agent.execute(:get_all_schemas)
  #
  #   # Query a class
  #   result = agent.execute(:query_class,
  #     class_name: "Song",
  #     where: { plays: { "$gte" => 1000 } },
  #     limit: 10
  #   )
  #
  # @example With session token for ACL-scoped queries
  #   agent = Parse::Agent.new(session_token: user.session_token)
  #   result = agent.execute(:query_class, class_name: "PrivateData")
  #
  # @example MCP Server for external AI agents (must enable first)
  #   Parse::Agent.mcp_enabled = true
  #   require 'parse/agent/mcp_server'
  #   Parse::Agent::MCPServer.run(port: 3001)
  #
  class Agent
    # Error hierarchy for agent operations
    # Provides granular exception handling for different failure modes.

    # Base error class for all agent errors
    class AgentError < StandardError; end

    # Security-related errors (blocked operations, injection attempts)
    # These should NEVER be swallowed - always re-raise
    class SecurityError < AgentError; end

    # Validation errors for invalid input
    class ValidationError < AgentError; end

    # Timeout errors for long-running operations
    class ToolTimeoutError < AgentError
      attr_reader :tool_name, :timeout

      def initialize(tool_name, timeout)
        @tool_name = tool_name
        @timeout = timeout
        super("Tool '#{tool_name}' timed out after #{timeout} seconds")
      end
    end

    # Global configuration for MCP server feature
    # Must be explicitly enabled before using MCP server
    @mcp_enabled = false

    class << self
      # @!attribute [rw] mcp_enabled
      #   Whether the MCP server feature is enabled.
      #   Must be set to true before requiring 'parse/agent/mcp_server'.
      #   @return [Boolean] true if MCP server is enabled (default: false)
      attr_accessor :mcp_enabled

      # Check if MCP server feature is enabled
      # @return [Boolean]
      def mcp_enabled?
        @mcp_enabled == true
      end

      # Enable MCP server and load the server module
      # @param port [Integer] optional port to configure (default: Parse.mcp_server_port or 3001)
      # @return [Class] the MCPServer class
      # @raise [RuntimeError] if MCP server feature is not enabled via Parse.mcp_server_enabled
      # @note EXPERIMENTAL: MCP server is not fully implemented. You must enable it first:
      #   Parse.mcp_server_enabled = true
      #
      # @example Basic usage
      #   Parse.mcp_server_enabled = true
      #   Parse::Agent.enable_mcp!
      #
      # @example With custom port
      #   Parse.mcp_server_enabled = true
      #   Parse.mcp_server_port = 3002
      #   Parse::Agent.enable_mcp!
      #
      # @example With remote API (OpenAI)
      #   Parse.mcp_server_enabled = true
      #   Parse.configure_mcp_remote_api(
      #     provider: :openai,
      #     api_key: ENV['OPENAI_API_KEY'],
      #     model: 'gpt-4'
      #   )
      #   Parse::Agent.enable_mcp!
      #
      # @example With remote API (Claude)
      #   Parse.mcp_server_enabled = true
      #   Parse.configure_mcp_remote_api(
      #     provider: :claude,
      #     api_key: ENV['ANTHROPIC_API_KEY'],
      #     model: 'claude-3-opus-20240229'
      #   )
      #   Parse::Agent.enable_mcp!
      def enable_mcp!(port: nil)
        unless Parse.mcp_server_enabled?
          raise RuntimeError, "MCP server is experimental and must be explicitly enabled. " \
            "Set Parse.mcp_server_enabled = true before calling enable_mcp!"
        end

        # Use provided port, or configured port, or default
        port ||= Parse.mcp_server_port || 3001

        @mcp_enabled = true
        require_relative "agent/mcp_server"
        MCPServer.default_port = port

        # Pass remote API config if available
        if Parse.mcp_remote_api_configured?
          MCPServer.remote_api_config = Parse.mcp_remote_api
        end

        MCPServer
      end

      # Get the current MCP server port
      # @return [Integer] the configured port
      def mcp_port
        Parse.mcp_server_port || 3001
      end

      # Check if remote API is configured for MCP
      # @return [Boolean]
      def mcp_remote_api?
        Parse.mcp_remote_api_configured?
      end
    end

    # Available permission levels
    PERMISSION_LEVELS = {
      readonly: %i[
        get_all_schemas
        get_schema
        query_class
        count_objects
        get_object
        get_sample_objects
        aggregate
        explain_query
        call_method
      ].freeze,
      write: %i[
        create_object
        update_object
      ].freeze,
      admin: %i[
        delete_object
        create_class
        delete_class
      ].freeze
    }.freeze

    # All readonly tools (default)
    READONLY_TOOLS = PERMISSION_LEVELS[:readonly].freeze

    # Default query limits
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 1000

    # Default rate limiting configuration
    DEFAULT_RATE_LIMIT = 60   # requests per window
    DEFAULT_RATE_WINDOW = 60  # window in seconds

    # @return [Symbol] the current permission level (:readonly, :write, or :admin)
    attr_reader :permissions

    # @return [String, nil] the session token for ACL-scoped queries
    attr_reader :session_token

    # @return [Parse::Client] the Parse client instance to use
    attr_reader :client

    # @return [Array<Hash>] log of operations performed in this session
    attr_reader :operation_log

    # @return [RateLimiter] the rate limiter instance
    attr_reader :rate_limiter

    # Create a new Parse Agent instance.
    #
    # @param permissions [Symbol] the permission level (:readonly, :write, or :admin)
    # @param session_token [String, nil] optional session token for ACL-scoped queries
    # @param client [Parse::Client, Symbol] the client instance or connection name
    # @param rate_limit [Integer] maximum requests per window (default: 60)
    # @param rate_window [Integer] rate limit window in seconds (default: 60)
    #
    # @example Readonly agent with master key
    #   agent = Parse::Agent.new
    #
    # @example Agent with user session
    #   agent = Parse::Agent.new(session_token: "r:abc123...")
    #
    # @example Agent with custom rate limiting
    #   agent = Parse::Agent.new(rate_limit: 100, rate_window: 60)
    #
    def initialize(permissions: :readonly, session_token: nil, client: :default,
                   rate_limit: DEFAULT_RATE_LIMIT, rate_window: DEFAULT_RATE_WINDOW)
      @permissions = permissions
      @session_token = session_token
      @client = client.is_a?(Parse::Client) ? client : Parse::Client.client(client)
      @operation_log = []
      @rate_limiter = RateLimiter.new(limit: rate_limit, window: rate_window)
    end

    # Check if a tool is allowed under current permissions
    #
    # @param tool_name [Symbol] the name of the tool to check
    # @return [Boolean] true if the tool is allowed
    def tool_allowed?(tool_name)
      allowed_tools.include?(tool_name.to_sym)
    end

    # Get the list of tools allowed under current permissions
    #
    # @return [Array<Symbol>] list of allowed tool names
    def allowed_tools
      case @permissions
      when :readonly
        PERMISSION_LEVELS[:readonly]
      when :write
        PERMISSION_LEVELS[:readonly] + PERMISSION_LEVELS[:write]
      when :admin
        PERMISSION_LEVELS[:readonly] + PERMISSION_LEVELS[:write] + PERMISSION_LEVELS[:admin]
      else
        PERMISSION_LEVELS[:readonly]
      end
    end

    # Execute a tool by name with the given arguments.
    #
    # Implements granular exception handling:
    # - Security errors are re-raised (never swallowed)
    # - Rate limit errors include retry_after metadata
    # - Validation and Parse errors return structured error responses
    # - Unexpected errors are logged with stack traces
    #
    # @param tool_name [Symbol, String] the name of the tool to execute
    # @param kwargs [Hash] the arguments to pass to the tool
    # @return [Hash] the result of the tool execution with :success and :data or :error keys
    #
    # @example Query a class
    #   result = agent.execute(:query_class, class_name: "Song", limit: 10)
    #   if result[:success]
    #     puts result[:data][:results]
    #   else
    #     puts result[:error]
    #   end
    #
    # @raise [PipelineValidator::PipelineSecurityError] for blocked aggregation stages
    # @raise [ConstraintTranslator::ConstraintSecurityError] for blocked query operators
    #
    def execute(tool_name, **kwargs)
      tool_name = tool_name.to_sym

      # Check rate limit FIRST - before any processing
      @rate_limiter.check!

      unless tool_allowed?(tool_name)
        return error_response(
          "Permission denied: '#{tool_name}' requires #{required_permission_for(tool_name)} permissions. " \
          "Current level: #{@permissions}",
          error_code: :permission_denied
        )
      end

      begin
        result = Parse::Agent::Tools.send(tool_name, self, **kwargs)
        log_operation(tool_name, kwargs, result)
        success_response(result)

      # Security errors - NEVER swallow, always re-raise
      rescue PipelineValidator::PipelineSecurityError,
             ConstraintTranslator::ConstraintSecurityError => e
        log_security_event(tool_name, kwargs, e)
        raise  # Re-raise security errors to caller

      # Validation errors - return structured error response
      rescue ConstraintTranslator::InvalidOperatorError => e
        error_response(e.message, error_code: :invalid_query)

      # Timeout errors
      rescue ToolTimeoutError => e
        error_response(e.message, error_code: :timeout)

      # Rate limit errors (should be caught above, but handle just in case)
      rescue RateLimiter::RateLimitExceeded => e
        error_response(e.message, error_code: :rate_limited, retry_after: e.retry_after)

      # Invalid arguments
      rescue ArgumentError => e
        error_response("Invalid arguments: #{e.message}", error_code: :invalid_argument)

      # Parse API errors
      rescue Parse::Error => e
        error_response("Parse error: #{e.message}", error_code: :parse_error)

      # Unexpected errors - log with stack trace for debugging
      rescue StandardError => e
        warn "[Parse::Agent] Unexpected error in #{tool_name}: #{e.class} - #{e.message}"
        warn e.backtrace.first(5).join("\n") if e.backtrace
        error_response("#{tool_name} failed: #{e.message}", error_code: :internal_error)
      end
    end

    # Get tool definitions in MCP/OpenAI function calling format
    #
    # @param format [Symbol] the output format (:mcp or :openai)
    # @return [Array<Hash>] array of tool definitions
    def tool_definitions(format: :openai)
      Parse::Agent::Tools.definitions(allowed_tools, format: format)
    end

    # Request options hash for Parse API calls
    # @return [Hash] options to pass to client requests
    # @api private
    def request_opts
      opts = {}
      if @session_token
        opts[:session_token] = @session_token
        opts[:use_master_key] = false
      end
      opts
    end

    # Ask the agent a natural language question and get a response.
    # Requires an LLM API endpoint to be configured.
    #
    # @param prompt [String] the natural language question to ask
    # @param llm_endpoint [String] OpenAI-compatible API endpoint (default: LM Studio)
    # @param model [String] the model to use
    # @param max_iterations [Integer] maximum tool call iterations (default: 10)
    # @return [Hash] response with :answer and :tool_calls keys
    #
    # @example Ask about database structure
    #   agent = Parse::Agent.new
    #   result = agent.ask("How many users are in the database?")
    #   puts result[:answer]
    #
    # @example With custom endpoint
    #   result = agent.ask("Find songs with over 1000 plays",
    #     llm_endpoint: "http://localhost:1234/v1",
    #     model: "qwen2.5-7b-instruct")
    #
    def ask(prompt, llm_endpoint: nil, model: nil, max_iterations: 10)
      require "net/http"
      require "json"

      endpoint = llm_endpoint || ENV["LLM_ENDPOINT"] || "http://127.0.0.1:1234/v1"
      model_name = model || ENV["LLM_MODEL"] || "default"

      messages = [
        { role: "system", content: system_prompt },
        { role: "user", content: prompt }
      ]

      tool_calls_made = []

      max_iterations.times do |iteration|
        response = chat_completion(endpoint, model_name, messages)
        return { answer: nil, error: response[:error], tool_calls: tool_calls_made } if response[:error]

        message = response[:message]
        tool_calls = message["tool_calls"]

        # If no tool calls, we have the final answer
        unless tool_calls&.any?
          return {
            answer: message["content"],
            tool_calls: tool_calls_made
          }
        end

        # Process tool calls
        messages << message
        tool_calls.each do |tool_call|
          function = tool_call&.dig("function")
          next unless function # Skip malformed tool calls

          tool_name = function["name"]
          next unless tool_name # Skip if no tool name

          args = JSON.parse(function["arguments"] || "{}")

          # Execute the tool
          result = execute(tool_name.to_sym, **args.transform_keys(&:to_sym))
          tool_calls_made << { tool: tool_name, args: args, success: result[:success] }

          # Add tool result to messages
          messages << {
            role: "tool",
            tool_call_id: tool_call["id"],
            content: JSON.generate(result)
          }
        end
      end

      { answer: nil, error: "Max iterations reached", tool_calls: tool_calls_made }
    end

    private

    # System prompt for the agent - optimized for token efficiency
    def system_prompt
      <<~PROMPT
        Parse database assistant. Tools: get_all_schemas (list classes), get_schema (class fields), query_class (find objects), count_objects, get_object (by ID), aggregate (analytics), call_method (model methods). Use get_all_schemas first. Be concise.
      PROMPT
    end

    # Make a chat completion request to the LLM
    def chat_completion(endpoint, model, messages)
      uri = URI("#{endpoint}/chat/completions")
      http = Net::HTTP.new(uri.host, uri.port)
      http.read_timeout = 120

      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"

      body = {
        model: model,
        messages: messages,
        tools: tool_definitions.map { |t| { type: "function", function: t[:function] } },
        tool_choice: "auto",
        temperature: 0.1
      }

      request.body = JSON.generate(body)

      begin
        response = http.request(request)
        data = JSON.parse(response.body)

        if data["error"]
          { error: data["error"]["message"] }
        else
          { message: data["choices"][0]["message"] }
        end
      rescue StandardError => e
        { error: e.message }
      end
    end

    def required_permission_for(tool_name)
      PERMISSION_LEVELS.each do |level, tools|
        return level if tools.include?(tool_name)
      end
      :unknown
    end

    # Get the current authentication context
    # @return [Hash] auth type and master key usage info
    def auth_context
      @auth_context ||= if @session_token
        { type: :session_token, using_master_key: false }
      else
        { type: :master_key, using_master_key: true }
      end
    end

    # Keys that should never be logged for security reasons
    SENSITIVE_LOG_KEYS = %i[
      where pipeline session_token password secret token
      auth_data authData recovery_codes api_key master_key
    ].freeze

    def log_operation(tool_name, args, result)
      # Sanitize args by removing sensitive data
      sanitized_args = args.except(*SENSITIVE_LOG_KEYS)

      entry = {
        tool: tool_name,
        args: sanitized_args,
        timestamp: Time.now.iso8601,
        success: true,
        auth_type: auth_context[:type],
        using_master_key: auth_context[:using_master_key],
        permissions: @permissions
      }
      @operation_log << entry

      # Audit log master key usage
      if auth_context[:using_master_key]
        warn "[Parse::Agent:AUDIT] Master key operation: #{tool_name} at #{Time.now.iso8601}"
      end
    end

    # Log security events (blocked operations, injection attempts)
    # @param tool_name [Symbol] the tool that was called
    # @param args [Hash] the arguments passed
    # @param error [Exception] the security error
    def log_security_event(tool_name, args, error)
      entry = {
        type: :security_violation,
        tool: tool_name,
        error_class: error.class.name,
        error_message: error.message,
        timestamp: Time.now.iso8601,
        auth_type: auth_context[:type],
        permissions: @permissions
      }

      # Add specific info based on error type
      case error
      when PipelineValidator::PipelineSecurityError
        entry[:stage] = error.stage if error.respond_to?(:stage)
        entry[:reason] = error.reason if error.respond_to?(:reason)
      when ConstraintTranslator::ConstraintSecurityError
        entry[:operator] = error.operator if error.respond_to?(:operator)
        entry[:reason] = error.reason if error.respond_to?(:reason)
      end

      @operation_log << entry

      # Always warn on security events
      warn "[Parse::Agent:SECURITY] #{error.class.name}: #{error.message}"
      warn "[Parse::Agent:SECURITY] Tool: #{tool_name}, Auth: #{auth_context[:type]}"
    end

    def success_response(data)
      { success: true, data: data }
    end

    def error_response(message, error_code: nil, retry_after: nil)
      entry = {
        error: message,
        error_code: error_code,
        timestamp: Time.now.iso8601,
        success: false
      }
      @operation_log << entry

      response = { success: false, error: message }
      response[:error_code] = error_code if error_code
      response[:retry_after] = retry_after if retry_after
      response
    end
  end
end

# Include the MetadataDSL in Parse::Object to enable agent metadata for all models.
# This adds class methods: agent_description, agent_method, agent_readonly, agent_write, agent_admin
# And instance methods: agent_description, property_descriptions, agent_methods
Parse::Object.include(Parse::Agent::MetadataDSL) if defined?(Parse::Object)
