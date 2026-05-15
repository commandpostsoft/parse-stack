require_relative "../../../test_helper"

# Unit tests for the signup-on-save behavior introduced in 4.0.1:
# `Parse::User.new(...).save!` now routes through the signup endpoint
# (`POST /parse/users`) when the new user has a `password`, instead of
# the raw class endpoint (`POST /parse/classes/_User`). This means
# `save!` now returns an object with a populated `session_token`,
# matching the Parse JS SDK contract. `auth_data`-only signups are
# deliberately NOT routed through this path -- OAuth signup remains
# the responsibility of the explicit `signup!` method.
#
# All tests stub the user's `client` so the unit suite does not require
# a running Parse Server.
class TestUserSaveSignup < Minitest::Test
  # Minimal stand-in for Parse::Response. Captures the methods that
  # Parse::User#signup_create and Parse::Object#create consult.
  class StubResponse
    attr_reader :result, :code, :error

    def initialize(result: {}, code: nil, error: nil)
      @result = result
      @code = code
      @error = error
    end

    def success?
      @code.nil? && @error.nil?
    end

    def error?
      !success?
    end
  end

  # Stand-in for Parse::Client. Records every routed call so tests can
  # assert which endpoint (create_user vs create_object vs update_object)
  # was actually exercised, and what attributes were sent.
  class StubClient
    attr_reader :calls

    # @param responses [Hash] map of endpoint symbol => StubResponse to
    #   return for that endpoint. Endpoints not listed return a default
    #   success response. Methods accept the same kwargs as the real
    #   Parse::Client; values are recorded into `calls` for inspection.
    def initialize(responses = {})
      @calls = []
      @responses = responses
    end

    def create_user(body, session_token: nil, **_opts)
      @calls << [:create_user, body, session_token]
      @responses.fetch(:create_user) { default_user_response }
    end

    def create_object(class_name, body, session_token: nil, **_opts)
      @calls << [:create_object, class_name, body, session_token]
      @responses.fetch(:create_object) { default_user_response }
    end

    def update_object(class_name, id, body, session_token: nil, **_opts)
      @calls << [:update_object, class_name, id, body, session_token]
      @responses.fetch(:update_object) { StubResponse.new(result: { "updatedAt" => "2026-05-15T00:00:01Z" }) }
    end

    def calls_to(method)
      @calls.select { |c| c.first == method }
    end

    private

    def default_user_response
      StubResponse.new(result: {
        "objectId" => "abc123",
        "createdAt" => "2026-05-15T00:00:00Z",
        "sessionToken" => "r:stub-session-token",
      })
    end
  end

  # Named subclass used by the callback test. ActiveModel's `model_name`
  # requires the class to be named (anonymous subclasses raise).
  class SignupCallbackUser < Parse::User
    cattr_accessor :callback_log
    self.callback_log = []
    before_create { self.class.callback_log << :before_create }
    after_create  { self.class.callback_log << :after_create }
  end

  def setup
    @original_signup_on_save = Parse::User.signup_on_save
    Parse::User.signup_on_save = true
  end

  def teardown
    Parse::User.signup_on_save = @original_signup_on_save
  end

  # Helper: build a new user wired to a stub client.
  def new_user_with_client(client, **attrs)
    user = Parse::User.new(attrs)
    user.define_singleton_method(:client) { client }
    user
  end

  # --------------------------------------------------------------------
  # Configuration flag
  # --------------------------------------------------------------------

  def test_signup_on_save_defaults_to_true
    # setup forces it to true; reload the gem-level default by reverting
    # to whatever the constant was assigned at class definition time.
    assert_equal true, Parse::User.signup_on_save
  end

  def test_signup_on_save_can_be_toggled
    Parse::User.signup_on_save = false
    refute Parse::User.signup_on_save
  ensure
    Parse::User.signup_on_save = true
  end

  def test_signup_on_save_is_inherited_by_subclasses
    # Use the already-named SignupCallbackUser to avoid leaving an
    # anonymous descendant in Parse::Object.descendants, which other
    # tests iterate via Parse::Model.find_class.
    original = SignupCallbackUser.signup_on_save
    assert_equal true, SignupCallbackUser.signup_on_save

    SignupCallbackUser.signup_on_save = false
    refute SignupCallbackUser.signup_on_save, "subclass override should apply locally"
    assert Parse::User.signup_on_save, "subclass override must not leak to parent"
  ensure
    SignupCallbackUser.signup_on_save = original if defined?(original)
  end

  # --------------------------------------------------------------------
  # Endpoint routing for new users
  # --------------------------------------------------------------------

  def test_new_user_with_password_routes_through_signup_endpoint
    client = StubClient.new
    user = new_user_with_client(client, username: "alice", password: "s3cret")

    assert user.save, "save should succeed against the stub"
    assert_equal 1, client.calls_to(:create_user).size,
                 "expected exactly one create_user (signup) call"
    assert_empty client.calls_to(:create_object),
                 "should not have fallen through to /classes/_User"
  end

  def test_new_user_with_auth_data_but_no_password_does_not_route_through_signup_endpoint
    # Federated-identity signups via auth_data must NOT be triggerable
    # from a mass-assigned save. POST /parse/users treats auth_data as
    # an identity claim against an existing user, so a Rails controller
    # doing `Parse::User.new(params); u.save!` with attacker-controlled
    # auth_data could otherwise plant another user's session token on
    # the in-memory object. OAuth signup is the responsibility of the
    # explicit `signup!` method.
    client = StubClient.new({ create_object: StubResponse.new(result: {
      "objectId" => "raw-id",
      "createdAt" => "2026-05-15T00:00:00Z",
    }) })
    user = new_user_with_client(client,
      username: "bob",
      auth_data: { facebook: { id: "1", access_token: "tok" } },
    )

    assert user.save
    assert_empty client.calls_to(:create_user),
                 "auth_data without password must not trigger the signup endpoint"
    assert_equal 1, client.calls_to(:create_object).size
    assert_nil user.session_token
  end

  def test_new_user_without_credentials_falls_through_to_class_endpoint
    client = StubClient.new({ create_object: StubResponse.new(result: {
      "objectId" => "raw-id",
      "createdAt" => "2026-05-15T00:00:00Z",
    }) })
    user = new_user_with_client(client, username: "carol")

    assert user.save
    assert_empty client.calls_to(:create_user),
                 "no credentials => signup endpoint must not be hit"
    assert_equal 1, client.calls_to(:create_object).size
    assert_equal Parse::Model::CLASS_USER, client.calls_to(:create_object).first[1]
    assert_nil user.session_token,
               "raw /classes/_User insert does not return a session token"
  end

  def test_signup_on_save_false_forces_class_endpoint_even_with_password
    Parse::User.signup_on_save = false
    client = StubClient.new({ create_object: StubResponse.new(result: {
      "objectId" => "raw-id",
      "createdAt" => "2026-05-15T00:00:00Z",
    }) })
    user = new_user_with_client(client, username: "dave", password: "s3cret")

    assert user.save
    assert_empty client.calls_to(:create_user)
    assert_equal 1, client.calls_to(:create_object).size
    assert_nil user.session_token
  end

  # --------------------------------------------------------------------
  # Existing users must keep using the update path
  # --------------------------------------------------------------------

  def test_existing_user_save_uses_update_endpoint_not_signup
    client = StubClient.new
    user = new_user_with_client(client, username: "eve", password: "s3cret")
    # Simulate a persisted user: stamp the id, disable autofetch (the
    # property writer below would otherwise try to round-trip through
    # the stub), and clear dirty state so only the new email change is
    # treated as the save's payload.
    user.id = "existing-id"
    user.disable_autofetch!
    user.send(:changes_applied!)
    # Now mutate a field to trigger an update save
    user.email = "eve@example.com"

    assert user.save
    assert_empty client.calls_to(:create_user),
                 "an existing user save must not hit the signup endpoint"
    assert_empty client.calls_to(:create_object),
                 "an existing user save must not hit create_object"
    assert_equal 1, client.calls_to(:update_object).size
  end

  # --------------------------------------------------------------------
  # Response application
  # --------------------------------------------------------------------

  def test_save_applies_session_token_from_signup_response
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u1",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:abc",
    }) })
    user = new_user_with_client(client, username: "frank", password: "s3cret")

    assert user.save
    assert_equal "r:abc", user.session_token
    assert user.logged_in?, "logged_in? should be true once session_token is set"
    assert_equal "u1", user.id
  end

  def test_save_returns_false_on_error_response
    client = StubClient.new({ create_user: StubResponse.new(
      result: {},
      code: Parse::Response::ERROR_USERNAME_TAKEN,
      error: "Account already exists for this username.",
    ) })
    user = new_user_with_client(client, username: "taken", password: "s3cret")
    # Suppress the "Error creating ..." stderr print from the create body
    capture_io { refute user.save, "save should return false on a signup error response" }

    assert_nil user.session_token, "no session token should be set on error"
  end

  def test_save_bang_raises_record_not_saved_on_error_response
    client = StubClient.new({ create_user: StubResponse.new(
      result: {},
      code: Parse::Response::ERROR_USERNAME_TAKEN,
      error: "Account already exists for this username.",
    ) })
    user = new_user_with_client(client, username: "taken", password: "s3cret")

    capture_io do
      assert_raises(Parse::RecordNotSaved) { user.save! }
    end
  end

  # --------------------------------------------------------------------
  # Callbacks
  # --------------------------------------------------------------------

  def test_save_runs_before_create_and_after_create_callbacks
    SignupCallbackUser.callback_log = []
    client = StubClient.new
    user = SignupCallbackUser.new(username: "grace", password: "s3cret")
    user.define_singleton_method(:client) { client }

    assert user.save
    assert_equal [:before_create, :after_create], SignupCallbackUser.callback_log
  end

  def test_subclass_inheriting_signup_on_save_routes_through_signup_endpoint
    client = StubClient.new
    user = SignupCallbackUser.new(username: "harry", password: "s3cret")
    user.define_singleton_method(:client) { client }

    assert user.save
    assert_equal 1, client.calls_to(:create_user).size,
                 "subclass should inherit signup_on_save=true and use the signup endpoint"
  end

  # --------------------------------------------------------------------
  # Subsequent saves should not re-send the password
  # --------------------------------------------------------------------

  def test_password_is_not_re_sent_on_subsequent_save
    client = StubClient.new
    user = new_user_with_client(client, username: "henry", password: "s3cret")

    assert user.save, "initial signup-via-save"
    user.email = "henry@example.com"
    assert user.save, "subsequent save (update)"

    update_call = client.calls_to(:update_object).first
    refute_nil update_call, "expected an update_object call after the initial save"
    body = update_call[3]
    refute body.key?(:password), "password should not be re-sent on subsequent save"
    refute body.key?("password"), "password should not be re-sent on subsequent save"
    assert(body.key?(:email) || body.key?("email"),
           "expected email change to be present in update body, got: #{body.inspect}")
  end

  # --------------------------------------------------------------------
  # Request body shape
  # --------------------------------------------------------------------

  def test_signup_request_body_includes_user_supplied_fields
    client = StubClient.new
    user = new_user_with_client(client,
      username: "iris",
      password: "p4ss",
      email: "iris@example.com",
    )

    assert user.save
    body = client.calls_to(:create_user).first[1]
    assert_equal "iris", body[:username] || body["username"]
    assert_equal "p4ss", body[:password] || body["password"]
    assert_equal "iris@example.com", body[:email] || body["email"]
  end

  # --------------------------------------------------------------------
  # Defensive filtering: request body
  # --------------------------------------------------------------------

  def test_signup_request_body_strips_acl
    # `attribute_updates` already filters [:id, :created_at, :updated_at]
    # via Parse::Properties::BASE_KEYS, so the load-bearing strip in
    # signup_create is :ACL (the remote-name remap of :acl). signup!
    # strips the same field for parity with Parse Server's own ACL
    # defaulting on the signup endpoint.
    client = StubClient.new
    user = new_user_with_client(client, username: "jade", password: "p4ss")
    user.acl.everyone(true, true) # mutate ACL so it appears in attribute_updates

    # Sanity-check: without the strip, :ACL would be in attribute_updates.
    # This confirms the assertion below is non-tautological.
    assert user.attribute_updates.key?(:ACL),
           "attribute_updates must include :ACL for this test to be meaningful"

    assert user.save
    body = client.calls_to(:create_user).first[1]
    refute body.key?(:ACL),  "ACL must not be sent to /parse/users (parity with signup!)"
    refute body.key?("ACL"), "ACL (string key) must not be sent to /parse/users"
  end

  # --------------------------------------------------------------------
  # Defensive filtering: response body
  # --------------------------------------------------------------------

  def test_save_does_not_apply_server_supplied_auth_data_from_response
    # A compromised or MITM'd Parse Server (or a buggy custom adapter)
    # must not be able to plant authData onto the in-memory user via
    # the signup-via-save path. Only sessionToken and emailVerified are
    # accepted from the response body.
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u9",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "authData" => { "facebook" => { "id" => "attacker-fb-id", "access_token" => "stolen" } },
    }) })
    user = new_user_with_client(client, username: "kim", password: "p4ss")

    assert user.save
    assert_equal "r:legit", user.session_token, "sessionToken must still be applied"
    assert_nil user.auth_data, "server-supplied authData must NOT be applied"
  end

  def test_save_does_not_apply_server_supplied_username_or_password_from_response
    # The response could try to redirect the in-memory object to a
    # different username (account-takeover surface). Reject anything
    # outside the allow-list.
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u10",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "username" => "attacker",
      "password" => "rewritten",
    }) })
    user = new_user_with_client(client, username: "leo", password: "p4ss")

    assert user.save
    assert_equal "leo", user.username,
                 "username from response body must NOT clobber the user's chosen username"
    assert_equal "p4ss", user.password,
                 "password from response body must NOT replace the caller's password"
  end

  # --------------------------------------------------------------------
  # Defense in depth: mass-assignment filter
  # --------------------------------------------------------------------

  def test_mass_assigned_auth_data_is_stripped_at_construction
    # Backstop for any code path that doesn't route through Parse::User#create
    # (e.g. batch save via BatchOperation#change_requests, transaction
    # save_all). PROTECTED_MASS_ASSIGNMENT_KEYS filters auth_data at
    # construction so the dirty-tracked field never appears in
    # attribute_updates and is never forwarded to /parse/users by any
    # downstream save mechanism.
    user = Parse::User.new(
      username: "nora",
      password: "p4ss",
      auth_data: { facebook: { id: "attacker-id", access_token: "stolen" } },
    )

    assert_nil user.auth_data,
               "auth_data must be stripped by the mass-assignment filter when assigned via constructor"
    refute user.attribute_updates.key?(:authData),
           "authData (remote-mapped) must not appear in attribute_updates after mass-assignment filtering"
    refute user.attribute_updates.key?(:auth_data),
           "auth_data must not appear in attribute_updates after mass-assignment filtering"
  end

  def test_explicit_auth_data_setter_still_works_for_trusted_callers
    # The mass-assignment filter must not block direct programmatic
    # assignment - server code that explicitly invokes the typed setter
    # is asserting trust in its own input.
    user = Parse::User.new(username: "olga", password: "p4ss")
    user.auth_data = { "facebook" => { "id" => "trusted-id", "access_token" => "ok" } }

    assert_equal({ "facebook" => { "id" => "trusted-id", "access_token" => "ok" } },
                 user.auth_data, "explicit setter must remain functional")
  end

  def test_save_applies_email_verified_from_signup_response
    # emailVerified is an allow-listed key: Parse Server can flag the
    # user as verified at signup time (e.g. via a beforeSignUp trigger
    # or a pre-trusted email domain).
    skip "_User has no emailVerified property declared by default" unless Parse::User.fields.key?(:email_verified)
    client = StubClient.new({ create_user: StubResponse.new(result: {
      "objectId" => "u11",
      "createdAt" => "2026-05-15T00:00:00Z",
      "sessionToken" => "r:legit",
      "emailVerified" => true,
    }) })
    user = new_user_with_client(client, username: "mia", password: "p4ss")

    assert user.save
    assert user.email_verified, "emailVerified should be applied from signup response"
  end
end
