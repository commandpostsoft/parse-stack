require_relative "../../test_helper"

# Tests the mass-assignment allowlist that prevents attacker-controlled
# params from overwriting permission-sensitive keys (acl, roles, objectId,
# sessionToken, ...) on Parse::Object subclasses.
class MassAssignmentProtectionTest < Minitest::Test
  class TestDocument < Parse::Object
    parse_class "TestDocument"
    property :title, :string
    property :body, :string
  end

  # NOTE: `acl` and `objectId` are deliberately NOT in the denylist —
  # `Document.new(acl: my_acl)` is legitimate developer code, and Rails
  # apps should filter attacker-controlled params via StrongParameters
  # before passing them to `Model.new` or `attributes=`. The model layer
  # only blocks fields that have no legitimate user-facing setter.

  def test_mass_assignment_allows_acl
    # ACL is a user-facing property; setting it via the constructor or
    # `attributes=` must work for legitimate developer code paths.
    doc = TestDocument.new
    acl = Parse::ACL.new
    acl.apply("role:Admin", read: true, write: true)
    doc.attributes = { "title" => "Hello", "acl" => acl }
    assert_equal "Hello", doc.title
    acl_json = doc.acl.as_json
    assert acl_json["role:Admin"], "developer-set ACL must be applied"
  end

  def test_mass_assignment_skips_session_token
    user = Parse::User.new
    user.attributes = { "username" => "alice", "sessionToken" => "r:stolen" }
    assert_nil user.session_token
  end

  def test_mass_assignment_skips_roles
    user = Parse::User.new
    user.attributes = { "username" => "alice", "roles" => ["Admin"] }
    # roles should not be writable via mass assignment
    refute_includes (user.respond_to?(:roles) ? user.roles : []), "Admin"
  end

  def test_mass_assignment_skips_created_at_updated_at
    doc = TestDocument.new
    past = Time.utc(1999, 1, 1)
    doc.attributes = { "title" => "Hello", "createdAt" => past.iso8601, "updatedAt" => past.iso8601 }
    refute_equal past.to_i, doc.created_at.to_i if doc.created_at
    refute_equal past.to_i, doc.updated_at.to_i if doc.updated_at
  end

  def test_mass_assignment_allows_normal_properties
    doc = TestDocument.new
    doc.attributes = { "title" => "Hello", "body" => "world" }
    assert_equal "Hello", doc.title
    assert_equal "world", doc.body
  end

  def test_internal_hydration_still_accepts_protected_keys
    # apply_attributes! with dirty_track: false (the default) is the trusted
    # internal hydration path used when building objects from Parse Server
    # responses. It must still accept server-issued sessionToken/ACL/etc.
    user = Parse::User.new
    user.apply_attributes!({ "username" => "alice", "sessionToken" => "r:legit" })
    assert_equal "r:legit", user.session_token
  end

  def test_protected_keys_set_is_frozen
    assert_predicate Parse::Properties::PROTECTED_MASS_ASSIGNMENT_KEYS, :frozen?
  end
end
