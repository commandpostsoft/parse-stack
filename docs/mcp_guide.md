# Parse Stack MCP Guide

## Overview

The Model Context Protocol (MCP) is a standardized JSON-RPC 2.0-based interface that lets external tools and agents interact with a server's capabilities in a structured way. Parse Stack exposes an MCP layer so any MCP-compatible client can query Parse data, inspect schemas, count objects, run aggregations, and invoke registered tools without writing application-specific integration code.

Three deployment modes are available:

- **Standalone HTTP server (`MCPServer`)** — a WEBrick process for dedicated MCP deployments.
- **Rack-mountable adapter (`MCPRackApp`)** — embeds inside an existing Sinatra or Rails application.
- **Direct in-process dispatcher (`MCPDispatcher`)** — a pure function for in-process usage, custom transports, and testing.

---

## Deployment Modes

### Standalone HTTP server (MCPServer)

`Parse::Agent::MCPServer` wraps `Parse::Agent::MCPRackApp` in a WEBrick process. It is the fastest path to a working MCP endpoint and is well-suited for dedicated tooling services.

**Prerequisites.** The server requires both an environment variable and a programmatic flag before `enable_mcp!` will proceed:

```ruby
# config/initializers/parse_mcp.rb (or equivalent boot file)
ENV["PARSE_MCP_ENABLED"] = "true"          # must be set in the environment
Parse.mcp_server_enabled = true            # must be set in code
```

**Starting the server:**

```ruby
Parse::Agent.enable_mcp!

Parse::Agent::MCPServer.run(
  port:        3001,
  host:        "127.0.0.1",     # default; do not bind to 0.0.0.0 without a firewall
  permissions: :readonly,        # :readonly, :write, or :admin
  api_key:     ENV["MCP_API_KEY"]
)
```

`MCPServer.run` is blocking. Trap signals are installed automatically (`INT`, `TERM` -> graceful shutdown).

**Authentication.** When `api_key` is set, every request to `/mcp` must include the `X-MCP-API-Key` header. The comparison uses `ActiveSupport::SecurityUtils.secure_compare` to prevent timing attacks.

**Additional endpoints exposed by the standalone server:**

| Path | Auth required | Purpose |
|------|--------------|---------|
| `/mcp` | Yes (if api_key set) | MCP JSON-RPC endpoint |
| `/health` | No | Monitoring / liveness check: `{"status":"ok","mcp_enabled":true}` |
| `/tools` | Yes (if api_key set) | Human-readable tool list |

Wire your load balancer's health check to `/health`.

---

### Embedded in a Rack app (MCPRackApp)

`Parse::Agent::MCPRackApp` is a Rack endpoint that accepts an **agent factory** — a callable (block or `agent_factory:` keyword, not both) invoked on every request. The factory is responsible for authenticating the request and returning a configured `Parse::Agent`. It must raise `Parse::Agent::Unauthorized` to signal any authentication failure.

The preferred construction is via the `Parse::Agent.rack_app` convenience method, which loads the adapter on demand:

```ruby
Parse::Agent.rack_app { |env| ... }
```

The verbose form `Parse::Agent::MCPRackApp.new { |env| ... }` is equivalent and is the underlying implementation.

**Transport-level checks** run before the factory is called:

- Only `POST` requests are accepted (405 otherwise).
- `Content-Type` must be `application/json` (415 otherwise).
- Body is capped at 1 MB by default (413 otherwise).
- JSON must be valid and not exceed nesting depth 20 (400 otherwise).

After those checks pass, the factory is called. If it raises `Parse::Agent::Unauthorized`, the adapter returns a sanitized 401 with a fixed JSON-RPC error body — no exception detail leaks to the caller. Any other exception from the factory returns a 500 with the same `"Internal error"` wire message.

#### 1. Rails

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mcp_app = Parse::Agent.rack_app(logger: Rails.logger) do |env|
    header = env["HTTP_AUTHORIZATION"].to_s
    token  = header.delete_prefix("Bearer ").strip

    raise Parse::Agent::Unauthorized.new("missing token", reason: :missing) if token.empty?

    # Replace with your real verification (Devise, JWT, Auth0, etc.)
    payload = MyJWTVerifier.verify!(token)  # raises on bad/expired token

    # Map application roles to Parse::Agent permission levels
    perms = payload["admin"] ? :write : :readonly

    # Use a shared Redis-backed limiter (see Rate Limiting section)
    Parse::Agent.new(
      permissions:  perms,
      session_token: payload["parse_session_token"],
      rate_limiter:  $shared_redis_limiter
    )
  rescue MyJWTVerifier::ExpiredToken
    raise Parse::Agent::Unauthorized.new("token expired", reason: :expired)
  rescue MyJWTVerifier::InvalidToken
    raise Parse::Agent::Unauthorized.new("token invalid", reason: :invalid)
  end

  mount mcp_app, at: "/mcp"
end
```

#### 2. Sinatra

Define the Rack app as a constant inside your Sinatra class, then mount it from `config.ru` using `Rack::Builder`'s `map`. Sinatra's class body does not expose the `map` DSL — it belongs to the outer builder context.

```ruby
# app.rb
require "sinatra/base"
require "parse-stack"

class MyApp < Sinatra::Base
  MCP_APP = Parse::Agent.rack_app do |env|
    token = env["HTTP_AUTHORIZATION"].to_s.delete_prefix("Bearer ").strip
    raise Parse::Agent::Unauthorized.new("missing token", reason: :missing) if token.empty?

    begin
      payload = MyJWTVerifier.verify!(token)
    rescue MyJWTVerifier::InvalidToken => e
      raise Parse::Agent::Unauthorized.new(e.message, reason: :invalid)
    end

    Parse::Agent.new(
      permissions:   payload["admin"] ? :write : :readonly,
      session_token: payload["parse_session_token"],
      rate_limiter:  $shared_redis_limiter
    )
  end

  get("/") { "ok" }
end
```

```ruby
# config.ru
require_relative "app"

map("/mcp") { run MyApp::MCP_APP }
run MyApp
```

#### 3. Plain Rack

```ruby
# config.ru
require "parse-stack"

Parse.connect("myapp",
  server_url:  ENV["PARSE_SERVER_URL"],
  app_id:      ENV["PARSE_APP_ID"],
  master_key:  ENV["PARSE_MASTER_KEY"]
)

mcp_app = Parse::Agent.rack_app do |env|
  api_key = env["HTTP_X_MCP_API_KEY"].to_s
  unless ActiveSupport::SecurityUtils.secure_compare(ENV["MCP_API_KEY"], api_key)
    raise Parse::Agent::Unauthorized.new("bad key", reason: :bad_api_key)
  end

  Parse::Agent.new(permissions: :readonly, rate_limiter: $shared_redis_limiter)
end

map("/mcp") { run mcp_app }
map("/")    { run ->(env) { [200, {"Content-Type" => "text/plain"}, ["ok"]] } }
```

#### MCP progress notifications via SSE (opt-in)

`MCPRackApp` supports Server-Sent Events for clients that want `notifications/progress` heartbeats:

```ruby
mcp_app = Parse::Agent.rack_app(streaming: true) do |env|
  # ... auth factory ...
end
```

When `streaming: true` is set and the client sends `Accept: text/event-stream`, the server holds the connection open and emits `notifications/progress` heartbeats every 2 seconds. Normal (non-streaming) clients are unaffected because the default is `streaming: false`.

**Client requirements:**
- Send `Accept: text/event-stream` in the request headers.
- Be prepared for an indefinitely open response until the tool call completes.

**Nginx configuration.** Add `X-Accel-Buffering: no` to prevent Nginx from buffering the SSE stream:

```nginx
location /mcp {
  proxy_pass http://backend;
  proxy_set_header X-Accel-Buffering no;
}
```

**`progress_callback:` parameter (reserved).** `MCPDispatcher.call` accepts an optional `progress_callback:` keyword argument. In v4.1.0 the parameter is accepted but the dispatcher never invokes it — heartbeats are emitted from the SSE transport layer, not from tool internals. The parameter exists now so the public API surface is stable across the v4.1 → v4.2 boundary. When v4.2 wires tool-internal progress reporting, the planned callback signature is `->(progress:, total: nil, message: nil)`, matching the MCP `notifications/progress` `params` shape. Code that passes `progress_callback:` today is forward-compatible but has no observable v4.1.0 effect.

---

### Direct in-process dispatcher (MCPDispatcher)

`Parse::Agent::MCPDispatcher.call` is a pure function: it takes an already-parsed body Hash and a `Parse::Agent` instance and returns `{ status: Integer, body: Hash }`. It performs no I/O, no HTTP parsing, and no authentication. The `body` value is the JSON-RPC response envelope (a Ruby Hash with string keys) — the caller is responsible for serializing it to JSON and writing it to the wire.

```ruby
require "parse/agent/mcp_dispatcher"

body   = JSON.parse(raw_request_body)   # caller parses
agent  = Parse::Agent.new(permissions: :readonly)

result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

# result[:status] => 200 (or 401 for Unauthorized)
# result[:body]   => { "jsonrpc" => "2.0", "id" => ..., "result" => {...} }

response_json = JSON.generate(result[:body])
```

The dispatcher accepts an optional `logger:` keyword for routing internal-error diagnostics:

```ruby
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent, logger: my_logger)
```

`MCPRackApp` forwards its `logger:` argument to the dispatcher automatically, so transport-level and handler-level diagnostics land in the same operator log.

**`MCPDispatcher` never raises.** All `StandardError` subclasses are caught and translated into JSON-RPC `-32603` error envelopes. The wire-level message in that envelope is the literal string `"Internal error"` — no class name, no message text, no backtrace. The class name and message are emitted to the logger (or `$stderr` via `Kernel#warn` as fallback) and are operator-only. `Parse::Agent::Unauthorized` produces a `-32001` error with HTTP status 401 in the returned hash.

Common uses for the direct dispatcher:

- Unit testing — construct agents with fixture data and call the dispatcher directly without starting a server. See the Testing section.
- Custom transports — WebSockets, stdio, or any other channel that delivers a parsed body.
- Composing inside a larger MCP server that handles its own routing and auth.

---

## Custom Authentication

The agent factory pattern gives you full control over authentication. Every request passes through the factory before any Parse operation is attempted.

**Complete example:**

```ruby
agent_factory = lambda do |env|
  # 1. Extract the bearer token from the Authorization header.
  raw = env["HTTP_AUTHORIZATION"].to_s
  token = raw.delete_prefix("Bearer ").strip

  if token.empty?
    raise Parse::Agent::Unauthorized.new("Authorization header missing", reason: :missing)
  end

  # 2. Verify the token (JWT, Auth0, Devise session, or static comparison).
  #    For static API keys, always use secure_compare:
  #
  #    unless ActiveSupport::SecurityUtils.secure_compare(ENV["STATIC_KEY"], token)
  #      raise Parse::Agent::Unauthorized.new("bad key", reason: :bad_api_key)
  #    end
  #
  #    For JWT:
  payload = MyJWTVerifier.verify!(token)  # raises on invalid/expired

  # 3. Map the verified identity to permissions.
  perms = case payload["role"]
    when "admin" then :write        # see WARNING below
    else              :readonly
  end

  # 4. Return a configured agent.
  Parse::Agent.new(
    permissions:   perms,
    session_token: payload["parse_session_token"],  # optional; scopes queries to user ACLs
    rate_limiter:  $shared_redis_limiter             # required for per-request deployments
  )

rescue MyJWTVerifier::ExpiredToken
  raise Parse::Agent::Unauthorized.new("token expired", reason: :expired)
rescue MyJWTVerifier::InvalidToken
  raise Parse::Agent::Unauthorized.new("token invalid", reason: :invalid)
end
```

**`Parse::Agent::Unauthorized` contract:**

```ruby
raise Parse::Agent::Unauthorized.new("human-readable message", reason: :symbol)
```

The `reason:` keyword is available as `e.reason` on the exception object. Any middleware that rescues `Unauthorized` upstream of `MCPRackApp` can read it. `MCPRackApp` itself logs only the exception class name (not `e.reason`) when a `logger:` is provided. The `reason` is never included in any HTTP response body.

The response the client always receives for an authentication failure is the fixed sanitized envelope:

```json
{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"Unauthorized"}}
```

Only `Parse::Agent::Unauthorized` should escape the factory. Any other exception becomes a 500 response with `"Internal error"` as the wire message. Rescue and re-raise all anticipated failures as `Unauthorized` or allow unexpected errors to propagate as-is.

**WARNING: `:admin` permissions over HTTP.** The `:admin` permission level enables destructive tools (`delete_object`, `create_class`, `delete_class`). Do not grant `:admin` in an HTTP-exposed agent factory unless you have explicitly considered what happens when that endpoint is called with a stolen credential, a misconfigured reverse proxy, or a logic error in your authorization check. Prefer `:write` for mutation access and reserve `:admin` for internal tooling behind a network boundary.

---

## Rate Limiting in Per-Request Deployments

### The problem

The bundled `Parse::Agent::RateLimiter` is an in-process sliding-window counter stored on the `Parse::Agent` instance. It works correctly in deployments that reuse a single agent across requests:

```
Standalone MCPServer
  creates ONE Parse::Agent at startup
  rate_limiter state persists across all requests  (correct)
```

When `MCPRackApp` calls an agent factory on every request, a new `Parse::Agent` is created each time. Because `RateLimiter` state lives on the instance, it resets on every call:

```
MCPRackApp (per-request factory)
  request 1 -> new Parse::Agent -> new RateLimiter (0 requests recorded)
  request 2 -> new Parse::Agent -> new RateLimiter (0 requests recorded)
  effectively no rate limiting
```

### The solution

Inject a shared, externally-stateful limiter:

```ruby
$shared_redis_limiter = MyRedisRateLimiter.new(
  key:    "mcp_rate_limit",
  limit:  60,
  window: 60
)

mcp_app = Parse::Agent.rack_app do |env|
  # ... auth ...
  Parse::Agent.new(
    permissions:  :readonly,
    rate_limiter: $shared_redis_limiter
  )
end
```

### Injected limiter protocol

An injected limiter must satisfy this interface:

```ruby
# The limiter must respond to #check! and raise
# Parse::Agent::RateLimitExceeded when the budget is exhausted.
# Parse::Agent::RateLimitExceeded is a top-level alias for
# Parse::Agent::RateLimiter::RateLimitExceeded.

class MyRedisRateLimiter
  def initialize(key:, limit:, window:)
    @key    = key
    @limit  = limit
    @window = window
  end

  def check!
    remaining = redis_sliding_window_increment(@key, @limit, @window)
    if remaining < 0
      raise Parse::Agent::RateLimitExceeded.new(
        retry_after: @window,
        limit:       @limit,
        window:      @window
      )
    end
    true
  end

  private

  def redis_sliding_window_increment(key, limit, window)
    # Your Redis INCR / EXPIRE or sorted-set sliding window implementation.
    # Return the number of remaining slots (negative means over limit).
  end
end
```

`Parse::Agent#initialize` validates the injected limiter at construction time:

```ruby
# Raises ArgumentError immediately if the limiter does not respond to #check!
Parse::Agent.new(rate_limiter: bad_object)
# => ArgumentError: rate_limiter must respond to #check!
```

**Fail-closed behavior.** If the injected limiter raises an error that is not `Parse::Agent::RateLimitExceeded` (for example, a `Redis::ConnectionError` when the backing store is unavailable), `Agent#execute` translates it into a synthetic `RateLimitExceeded` with a randomized `retry_after` between 1.0 and 5.0 seconds. This prevents the Redis-down condition from being distinguishable from a real rate limit signal. The original error is emitted to `$stderr` via `Kernel#warn` with the format `"[Parse::Agent] rate limiter failure: <Class>: <message>"` — it is operator-only and never reaches the client.

The `Parse::Agent::RateLimitExceeded` constant is a stable top-level alias — external limiters should raise it directly rather than the nested `Parse::Agent::RateLimiter::RateLimitExceeded`.

Per-user rate limiting follows the same pattern: key the Redis counter on the verified user identity extracted during authentication.

---

## Custom Tools

Prior to v4.1.0, adding application-specific tools required wrapping the dispatcher or monkey-patching the `Tools` module. v4.1.0 closes this gap with `Parse::Agent::Tools.register`.

### Registering custom tools

Register before the `MCPRackApp` or `MCPServer` starts handling requests. Registration is thread-safe (guarded by a mutex internally), but the registry is global to the process. Registering the same name again replaces the previous registration.

```ruby
Parse::Agent::Tools.register(
  name:        :breakdown_captures,
  description: "Count captures grouped by user/project/team/org with optional date window",
  parameters:  {
    type: "object",
    properties: {
      group_by: {
        type: "string",
        enum: ["user", "project", "team", "org"],
        description: "Dimension to group by"
      },
      since: {
        type: "string",
        description: "ISO8601 lower bound (inclusive)"
      }
    },
    required: ["group_by"]
  },
  permission: :readonly,
  timeout:    30,
  handler:    ->(agent, **args) { MyApp::BreakdownService.call(**args) }
)
```

**How registered tools integrate with the runtime:**
- They appear in `tools/list` responses alongside built-in tools, filtered by the current agent's permission level (a tool registered with `permission: :write` will not appear for a `:readonly` agent).
- Tool calls route through `Agent#execute`, which means they go through permission checking, rate limiting, and `ActiveSupport::Notifications` instrumentation exactly like built-in tools.
- The handler lambda receives the agent instance as its first argument and keyword arguments matching the parameters schema.

Registering a name that matches a built-in tool replaces the built-in in `tools/list` and `tools/call` responses. To restore built-in-only state (useful in test teardown, parallel to `Parse::Agent::Prompts.reset_registry!`), call `Parse::Agent::Tools.reset_registry!`.

**v4.1.0 and later:** use `Parse::Agent::Tools.register` as shown above.

**Pre-4.1.0 workaround:** wrap the dispatcher:

```ruby
# Pre-4.1.0 only — dispatcher-wrap pattern
original_call = Parse::Agent::MCPDispatcher.method(:call)

module CustomDispatch
  def self.call(body:, agent:, logger: nil)
    if body.dig("method") == "tools/call" &&
       body.dig("params", "name") == "breakdown_captures"
      # handle it here, return { status: 200, body: jsonrpc_result }
    else
      original_call.call(body: body, agent: agent, logger: logger)
    end
  end
end
```

---

## Prompts

Prompts are named instruction templates that an MCP client can request by name, optionally passing arguments. The dispatcher exposes them via `prompts/list` and `prompts/get`.

### Built-in prompts

| Name | Description |
|------|-------------|
| `parse_conventions` | Generic Parse platform conventions (objectId shape, pointer/date formats, system classes). Fetch once and prepend to your LLM system message. |
| `parse_relations` | ASCII diagram of class relationships derived from `belongs_to` and `has_many :through => :relation`. Accepts an optional `classes` argument (comma-separated subset). |
| `explore_database` | Survey all Parse classes: list them, count each, and summarize what each appears to store. |
| `class_overview` | Describe a class in detail: schema, total count, and sample objects. Requires `class_name`. |
| `count_by` | Count objects in a class grouped by a field. Requires `class_name` and `group_by`. |
| `recent_activity` | Show the most recently created objects in a class. Requires `class_name`; optional `limit` (default 10, max 100). |
| `find_relationship` | Find objects in one class related to a given object in another via a pointer field. Requires `parent_class`, `parent_id`, `child_class`, `pointer_field`. |
| `created_in_range` | Count and sample objects created within a date range. Requires `class_name` and `since` (ISO8601); optional `until`. |

### Registering custom prompts

Register before the `MCPRackApp` or `MCPServer` starts handling requests. Registration is thread-safe (guarded by an internal mutex), but the registry is global to the process.

```ruby
Parse::Agent::Prompts.register(
  name:        "team_health",
  description: "Summary of team activity in the last 30 days",
  arguments: [
    { "name" => "team_id", "description" => "Parse objectId of the team", "required" => true }
  ],
  renderer: ->(args) {
    since = (Time.now - 30 * 86400).utc.iso8601
    "Show activity for team #{args["team_id"]} since #{since}. " \
    "Use count_objects and query_class to report events, members, and recent changes."
  }
)
```

A renderer lambda may return either:

- A `String` — used directly as the MCP message text. Description defaults to `"Parse analytics prompt: <name>"`.
- A `Hash` with `:description` and `:text` keys — both are used verbatim. This is the only way to customize the per-render description.

```ruby
# Hash form — overrides description per render
renderer: ->(args) {
  {
    description: "Team #{args["team_id"]} health report",
    text:        "Analyze team #{args["team_id"]} activity since #{Time.now - 30 * 86400}."
  }
}
```

Registering a name that matches a built-in replaces the built-in in `prompts/list` and `prompts/get` responses. To restore built-in-only state (useful in test teardown), call `Parse::Agent::Prompts.reset_registry!`.

---

## MCP Protocol Surface

All requests must be HTTP `POST` to the mounted path with `Content-Type: application/json`.

### Supported methods

| Method | Description |
|--------|-------------|
| `initialize` | MCP handshake. Returns protocol version, server capabilities, and server name/version. |
| `tools/list` | Returns all tools available to the current agent (filtered by permission level). Includes custom registered tools. |
| `tools/call` | Executes a named tool with arguments. Tool-level errors return `isError: true` in `content`, not a JSON-RPC `error` field. |
| `prompts/list` | Returns all available prompts (built-in plus registered). |
| `prompts/get` | Renders a named prompt with arguments. Returns `{ description, messages }`. |
| `resources/list` | Lists virtual resources for each Parse class: `parse://<ClassName>/schema`, `/count`, `/samples`. |
| `resources/read` | Reads a resource by URI. Supported kinds: `schema`, `count`, `samples`. |
| `ping` | No-op. Returns an empty result `{}`. |

**Pagination.** `tools/list` and `prompts/list` return the full registry in a single response — there is no `cursor`/`nextCursor` pagination. The MCP 2024-11-05 spec marks pagination as optional for these endpoints. With dozens of registered tools and prompts the response stays small; practical experience suggests keeping each registry under roughly 100 entries before considering grouping, namespacing, or pruning. Aggregate-style features like `resources/list` (which scales with the Parse class count) are similarly unpaginated.

**MCP protocol version upgrade path.** `Parse::Agent::MCPDispatcher::PROTOCOL_VERSION` is pinned to `"2024-11-05"`. To track a newer MCP version, update this constant and verify the `initialize` handshake response, the capability declaration shape, and any new error codes against the target version's schema. Most v4.1.0 features (Tools.register, get_objects, SSE progress, COLLSCAN refusal) are protocol-version-independent, but spec-level fields like `serverInfo` and capability flags may shift between MCP versions.

### Batch pointer resolution: `get_objects`

When you need to dereference multiple pointers, use `get_objects(class_name:, ids:, include:)` instead of N separate `get_object` calls. The batch tool resolves all IDs in a single Parse API request and is significantly cheaper for both latency and tokens.

```ruby
result = agent.execute(:get_objects,
  class_name: "User",
  ids:        ["abc123", "def456", "xyz789"],
  include:    ["team"]      # optional pointer fields to resolve
)
# result[:data] =>
# {
#   class_name: "User",
#   objects:    { "abc123" => {...user}, "def456" => {...user} },
#   missing:    ["xyz789"],   # ids that did not match any document
#   requested:  3,
#   found:      2
# }
```

Three contract details worth knowing:

- **50-id cap.** The tool deduplicates `ids` and rejects calls where the deduplicated count exceeds 50. Use `query_class` with a `where: { "objectId" => { "$in" => [...] } }` filter for larger sets.
- **Hash-keyed response.** `objects` is a Hash keyed by `objectId`, not an Array, so client code can look up by id without scanning. Missing ids appear in the separate `missing` array.
- **agent_fields allowlist inheritance.** If the underlying class declares `agent_fields :only, :these` in its model, the batch fetch applies the same allowlist as a `keys:` projection — PII trimming is consistent with the single-object `get_object` path.

### Error codes

| Code | Name | When used |
|------|------|-----------|
| `-32700` | Parse error | Body is invalid JSON, wrong content-type, or body exceeds size limit. |
| `-32601` | Method not found | The `method` string is not one of the supported methods above. |
| `-32602` | Invalid params | Missing or malformed arguments (tool name, resource URI, prompt arguments). |
| `-32603` | Internal error | Unexpected `StandardError` inside a handler. Wire body is the literal string `"Internal error"` — no class name, no message, no backtrace. Class and message are emitted to the operator's logger only. |
| `-32001` | Unauthorized | `Parse::Agent::Unauthorized` raised by the agent factory or a tool. HTTP status 401. |

For tool-call failures that are not protocol errors (a query that returns no results, a class that does not exist), the dispatcher returns HTTP 200 with `isError: true` inside the `content` array — not a JSON-RPC error code.

---

## Performance and Timeouts

### Tool timeout table

Each tool runs inside a `Timeout.timeout` block. The default timeouts are:

| Tool | Timeout (seconds) |
|------|--------------------|
| `aggregate` | 60 |
| `query_class` | 30 |
| `explain_query` | 30 |
| `call_method` | 60 |
| `get_all_schemas` | 15 |
| `get_schema` | 10 |
| `count_objects` | 20 |
| `get_object` | 10 |
| `get_sample_objects` | 15 |

Custom tools registered via `Parse::Agent::Tools.register` default to 30 seconds unless a `timeout:` value is supplied.

When a timeout fires, `Agent#execute` returns `{ success: false, error_code: :timeout }` with a message suggesting the client narrow the filter or add an index.

### MongoDB `maxTimeMS` pushdown

The `query_class` and `aggregate` tools push the tool timeout (minus a 5-second buffer) down to MongoDB as `maxTimeMS`. This ensures that if the Ruby-level `Timeout` fires, MongoDB also cancels the query rather than continuing to consume server resources.

When MongoDB cancels an operation due to `maxTimeMS`, it raises `Parse::MongoDB::ExecutionTimeout`. `Agent#execute` catches this and returns:

```ruby
{ success: false, error_code: :timeout, error: "Query exceeded time limit. Narrow the filter or add an index." }
```

### Response size cap

`MCPDispatcher` enforces `MAX_TOOL_RESPONSE_BYTES = 4_194_304` (4 MiB) on serialized tool results. When a `tools/call` response would exceed this limit, the dispatcher returns `isError: true` with a message instructing the client to narrow the query (lower `limit:`, project fewer fields with `keys:`/`select:`, or add stricter `where:` constraints). The oversized payload is never buffered or written to the wire.

### `explain_query` and COLLSCAN refusal

To detect and block full-collection scans at the tool level, set the global opt-in flag:

```ruby
Parse::Agent.refuse_collscan = true
```

With this flag set, `explain_query` will return an error if the query plan shows a `COLLSCAN` (full collection scan) stage, rather than executing it. This is useful in production environments where unindexed queries against large collections can cause performance problems.

Per-class override via the `agent_allow_collscan` DSL — for small lookup tables (Roles, Config, feature flags) where a scan is cheap and expected, and forcing an index would be pointless:

```ruby
class Role < Parse::Object
  agent_allow_collscan  # small lookup table, scan is fine
end

class FeatureFlag < Parse::Object
  agent_allow_collscan
end
```

The DSL takes no arguments — its presence in the class body opts that class out. Without `refuse_collscan` set globally, the per-class declaration is a no-op (no extra overhead).

---

## Observability

### MCPRackApp logger

Pass a logger at construction time and `MCPRackApp` will emit:

- Auth failures at `warn` level: `"[Parse::Agent::MCPRackApp] Unauthorized: <ExceptionClass>"` (class name only, no message).
- Factory errors (non-Unauthorized) at `warn` level: `"[Parse::Agent::MCPRackApp] Factory error: <ExceptionClass>"` followed by the backtrace.

```ruby
Parse::Agent.rack_app(logger: Rails.logger) do |env|
  # ... factory ...
end
```

### MCPDispatcher logger

When `MCPRackApp` has a logger, it is forwarded to `MCPDispatcher.call(logger: ...)` automatically. The dispatcher emits internal errors in the format:

```
[Parse::Agent::MCPDispatcher] <ExceptionClass>: <exception message>
```

This line goes to the logger when one is provided, or to `$stderr` via `Kernel#warn` when not. It is the only place the exception class and message are visible — they are never included in the wire response.

### ActiveSupport::Notifications

Every tool call dispatched through `Agent#execute` fires the `"parse.agent.tool_call"` notification. The payload is sanitized: sensitive argument keys (`where:`, `pipeline:`, `session_token:`, `password:`, etc.) are stripped before the payload is published.

**Payload keys:**

| Key | Type | Present |
|-----|------|---------|
| `:tool` | Symbol | Always |
| `:args_keys` | Array<Symbol> | Always — argument keys with SENSITIVE_LOG_KEYS removed |
| `:auth_type` | Symbol | Always — `:session_token` or `:master_key` |
| `:using_master_key` | Boolean | Always |
| `:permissions` | Symbol | Always — `:readonly`, `:write`, or `:admin` |
| `:success` | Boolean | Always (set at block exit) |
| `:result_size` | Integer | Success only — serialized byte count |
| `:error_class` | String | Failure only — exception class name |
| `:error_code` | Symbol | Failure only — `:security_blocked`, `:invalid_query`, `:timeout`, `:rate_limited`, `:invalid_argument`, `:parse_error`, `:internal_error`, or `:permission_denied` |

**Datadog / StatsD subscriber example:**

```ruby
ActiveSupport::Notifications.subscribe("parse.agent.tool_call") do |name, started, finished, _id, payload|
  duration_ms = ((finished - started) * 1000).round(2)

  tags = [
    "tool:#{payload[:tool]}",
    "permissions:#{payload[:permissions]}",
    "auth_type:#{payload[:auth_type]}",
    "success:#{payload[:success]}",
  ]

  if payload[:success]
    $statsd.histogram("parse.agent.tool.duration_ms", duration_ms, tags: tags)
    $statsd.increment("parse.agent.tool.success", tags: tags)
    if payload[:result_size]
      $statsd.histogram("parse.agent.tool.result_bytes", payload[:result_size], tags: tags)
    end
  else
    error_tags = tags + ["error_code:#{payload[:error_code]}"]
    $statsd.increment("parse.agent.tool.error", tags: error_tags)
    $statsd.histogram("parse.agent.tool.duration_ms", duration_ms, tags: error_tags)
  end
end
```

---

## Concurrency Contract

### What is thread-safe

- `Parse::Agent::MCPRackApp` is thread-safe. It holds no mutable state after construction; all per-request state lives in the agent instance created by the factory.
- `Parse::Agent::Prompts` registry uses an internal mutex. It is safe to call `Prompts.register` from any thread, but practical advice is to register all prompts at boot before serving requests.
- `Parse::Agent::Tools` registry follows the same threading model as `Prompts`.
- Per-request agent isolation: `MCPRackApp` constructs a fresh `Parse::Agent` per request via the agent factory. These agents share only the process-wide rate limiter passed as `rate_limiter:`. Per-instance state (`@conversation_history`, `@operation_log`, token counters) is scoped to a single request and discarded when it ends. This eliminates cross-request state leakage that was present when a single long-lived agent was shared.

### What is NOT thread-safe

`Parse::Agent` itself is not safe to share across threads. The `@conversation_history`, `@operation_log`, token counters, and `@last_request`/`@last_response` attributes are not protected by a mutex. Create a new agent per request (the `MCPRackApp` factory pattern enforces this) or per thread.

If you are using the standalone `MCPServer`, it creates one agent per request internally via its own factory — you do not need to manage this yourself.

---

## Testing Your MCP Integration

The cleanest test approach is to call `MCPDispatcher.call` directly, bypassing HTTP entirely. Construct an agent with the permissions and state relevant to the scenario, pass a parsed body, and assert on the returned status and body.

```ruby
require "parse/agent/mcp_dispatcher"

# Happy path: tools/list
agent  = Parse::Agent.new(permissions: :readonly)
body   = { "jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {} }
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

assert_equal 200, result[:status]
tools = result[:body]["result"]["tools"]
assert tools.any? { |t| t["name"] == "query_class" }
```

```ruby
# Unknown method -> -32601
body   = { "jsonrpc" => "2.0", "id" => 2, "method" => "no_such_method", "params" => {} }
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

assert_equal 200, result[:status]
assert_equal(-32601, result[:body]["error"]["code"])
```

```ruby
# Invalid params -> -32602
body   = { "jsonrpc" => "2.0", "id" => 3, "method" => "tools/call",
           "params" => {} }   # missing "name"
result = Parse::Agent::MCPDispatcher.call(body: body, agent: agent)

assert_equal 200, result[:status]
assert_equal(-32602, result[:body]["error"]["code"])
```

```ruby
# Test the Unauthorized path via MCPRackApp (factory-level auth test)
require "parse/agent/mcp_rack_app"

app = Parse::Agent::MCPRackApp.new do |env|
  raise Parse::Agent::Unauthorized.new("no key", reason: :missing)
end

env = {
  "REQUEST_METHOD" => "POST",
  "CONTENT_TYPE"   => "application/json",
  "rack.input"     => StringIO.new('{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}'),
}
status, _headers, body = app.call(env)

assert_equal 401, status
assert_equal(-32001, JSON.parse(body.first)["error"]["code"])
```

**Key properties of `MCPDispatcher.call`:**
- It never raises. All exceptions are caught and returned as error envelopes.
- The HTTP status in the returned hash is 200 for everything except `Unauthorized` (401). Even `-32603` internal errors return status 200.
- The dispatcher is stateless; you can call it in parallel from test threads without coordination.

---

## Aggregation Results: `.raw` vs `.results`

When using the `aggregate` tool with a `$group` pipeline stage, the rows returned by MongoDB are not full Parse objects — they have no `_created_at` or `_updated_at` fields. v4.1.0 fixes `Aggregation#results` to distinguish these cases by checking for those timestamp fields on each raw document.

- **`.results`** on a `$group` pipeline: returns an array of `Parse::AggregationResult` objects (not `Parse::Object`). These are value objects with hash-like field access. They do not have `objectId`, `createdAt`, or `updatedAt`.
- **`.results`** on a pipeline that preserves full Parse documents (e.g., `$match` only): returns typed `Parse::Object` instances.
- **`.raw`**: returns the raw array of hashes from the aggregation response. Always works regardless of pipeline shape; prefer this in custom tool handlers when you need simple hash access.

Custom tool handlers that aggregate with `$group` should prefer `.raw` for straightforward hash access, or use `.results` with the awareness that the objects are `Parse::AggregationResult`, not `Parse::Object`, and therefore lack standard Parse object methods.

**`Parse::AggregationResult` interface.** Value object returned for non-document aggregation rows. Reading the source isn't required — the contract is small:

```ruby
row = result[:data][:results].first
# Original field names (string keys) — works for any pipeline output.
row["_id"]            # the $group key value
row["count"]
# Snake-cased symbol access — useful when the pipeline produces camelCase field names.
row[:total_plays]     # if the projection was { "totalPlays" => ... }
# Method-style access via method_missing — same snake-cased keys.
row.total_plays
# Convenience.
row.to_h              # Hash of snake-cased symbol keys to values
row.raw               # Hash of original keys as returned by MongoDB
```

What it does **not** have: `objectId`, `createdAt`, `updatedAt`, `save`, `destroy`, `acl`, or any Parse persistence methods. Treating one as a `Parse::Object` will raise `NoMethodError`. If a handler needs to differentiate at runtime, check `is_a?(Parse::AggregationResult)`.

```ruby
# In a custom tool handler:
result = agent.execute(:aggregate,
  class_name: "Song",
  pipeline: [
    { "$group" => { "_id" => "$genre", "count" => { "$sum" => 1 } } },
    { "$sort"  => { "count" => -1 } },
  ]
)

if result[:success]
  rows = result[:data][:results]   # Array of hashes: [{"_id"=>"Rock","count"=>4200}, ...]
  rows.each { |row| puts "#{row["_id"]}: #{row["count"]}" }
end
```

---

## Security Notes

**Static-token comparisons must use secure compare.** String equality (`==`) is vulnerable to timing attacks. Use `ActiveSupport::SecurityUtils.secure_compare` for any comparison of secrets:

```ruby
unless ActiveSupport::SecurityUtils.secure_compare(ENV["EXPECTED_KEY"], provided_key)
  raise Parse::Agent::Unauthorized.new("bad key", reason: :bad_api_key)
end
```

**Only `Parse::Agent::Unauthorized` should escape the agent factory.** Any other exception from the factory becomes a 500 response with `"Internal error"` as the wire message. Rescue and re-raise all anticipated failures as `Unauthorized`. Do not let exception messages from third-party libraries reach the caller — they may contain user data or internal stack details.

**The dispatcher sanitizes internal errors.** `MCPDispatcher` rescues `StandardError` and returns a `-32603` envelope containing the literal string `"Internal error"` — no class name, no message, no backtrace. The exception class and message are emitted to the operator's logger (or `$stderr`). This applies to handler-level errors; factory-level errors are handled by `MCPRackApp` before the dispatcher is called.

**`:admin` permissions over HTTP.** `:admin` enables `delete_object`, `create_class`, and `delete_class`. Do not grant `:admin` from an HTTP-exposed factory without explicit intent. Treat it as equivalent to granting master-key access to any bearer of a valid token.

**Body size and nesting limits.** `MCPRackApp` rejects bodies larger than 1 MB and JSON with nesting depth greater than 20. The size limit can be adjusted with `max_body_size:`:

```ruby
Parse::Agent.rack_app(max_body_size: 512_000) { |env| ... }
```

**Content-Length and Transfer-Encoding enforcement (MCPServer).** The standalone `MCPServer` rejects requests with `Transfer-Encoding: chunked` (411 Length Required), requests with a missing `Content-Length` header (411), and requests where `Content-Length` exceeds the body size limit (413). These checks run before the body is read, preventing WEBrick from dechunking an unbounded stream.

**Resource URIs are validated.** `resources/read` validates the URI against `parse://<ClassName>/<kind>` before calling any tool. Class names must match Parse's identifier pattern (`[A-Za-z_][A-Za-z0-9_]*`). This prevents injection of arbitrary class names through the resource layer.

**The `logger:` kwarg on `MCPRackApp`.** When a logger is provided, auth failures are logged with the exception class name only (not the message or the `reason` attribute). Factory errors (non-Unauthorized) are logged with class name and full backtrace. Production deployments should pass a logger so failures are observable without exposing internals to clients:

```ruby
Parse::Agent.rack_app(logger: Rails.logger) { |env| ... }
```
