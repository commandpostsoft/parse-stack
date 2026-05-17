# encoding: UTF-8
# frozen_string_literal: true

module Parse
  class Agent
    # Error hierarchy for agent operations.
    #
    # Defined in a standalone file so the MCP transport layer
    # (Parse::Agent::MCPRackApp, Parse::Agent::MCPDispatcher) can rescue
    # these classes without transitively loading the full Parse::Agent
    # implementation. A downstream Rack mount only needs to know that
    # `raise Parse::Agent::Unauthorized` works.

    # Base error class for all agent errors
    class AgentError < StandardError; end

    # Security-related errors (blocked operations, injection attempts).
    # These should NEVER be swallowed - always re-raise.
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

    # Authentication failure for MCP transport adapters. Custom auth blocks
    # passed to Parse::Agent::MCPRackApp should raise this (or a subclass) to
    # signal an unauthenticated/unauthorized request; the transport layer
    # catches it and renders a sanitized 401 response.
    class Unauthorized < AgentError
      attr_reader :reason

      def initialize(message = "Unauthorized", reason: nil)
        @reason = reason
        super(message)
      end
    end
  end
end
