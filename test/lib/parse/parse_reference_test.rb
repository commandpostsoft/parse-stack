require_relative "../../test_helper"
require "minitest/autorun"

# Default field name + auto-population helper for parse_reference
class PRDefault < Parse::Object
  parse_class "PRDefault"
  property :title, :string
  parse_reference
  def autofetch!(*); nil; end
end

# Custom local name; remote defaults to camelCase of local
class PRCustomLocal < Parse::Object
  parse_class "PRCustomLocal"
  property :name, :string
  parse_reference :ref
  def autofetch!(*); nil; end
end

# Custom local AND remote names
class PRCustomBoth < Parse::Object
  parse_class "PRCustomBoth"
  property :label, :string
  parse_reference :ref, field: "refKey"
  def autofetch!(*); nil; end
end

# System-class subclass: format must produce "_User$id"
class PRSystemUserSub < Parse::User
  parse_class "_User"
  parse_reference
  def autofetch!(*); nil; end
end

class PRParentForSubclass < Parse::Object
  parse_class "PRParentForSubclass"
  property :title, :string
  parse_reference
  def autofetch!(*); nil; end
end

# Child redeclares parse_reference -- must NOT register a second callback
class PRChildRedeclares < PRParentForSubclass
  parse_class "PRChildRedeclares"
  parse_reference
end

class ParseReferenceTest < Minitest::Test
  def setup
    Parse.setup(
      server_url: "https://test.parse.com",
      application_id: "test",
      api_key: "test",
    )
  end

  def test_format_helper
    assert_equal "Post$abc123",
                 Parse::Core::ParseReference.format("Post", "abc123")
    assert_nil Parse::Core::ParseReference.format(nil, "abc")
    assert_nil Parse::Core::ParseReference.format("Post", nil)
    assert_nil Parse::Core::ParseReference.format("Post", "")
  end

  def test_parse_helper
    assert_equal ["Post", "abc123"], Parse::Core::ParseReference.parse("Post$abc123")
    assert_equal ["_User", "xyz"], Parse::Core::ParseReference.parse("_User$xyz")
    # IDs that themselves contain $ are preserved on the right side
    assert_equal ["Weird", "id$with$dollars"],
                 Parse::Core::ParseReference.parse("Weird$id$with$dollars")
    assert_equal [nil, nil], Parse::Core::ParseReference.parse(nil)
  end

  def test_parse_helper_rejects_malformed
    assert_raises(ArgumentError) { Parse::Core::ParseReference.parse("no-separator") }
    assert_raises(ArgumentError) { Parse::Core::ParseReference.parse(12345) }
  end

  def test_default_field_name_registers_property
    assert PRDefault.fields.key?(:parse_reference),
           "parse_reference should declare the :parse_reference local property"
    assert_equal "parseReference", PRDefault.field_map[:parse_reference].to_s,
                 "remote field defaults to camelCase form"
  end

  def test_custom_local_name_uses_camel_case_remote
    assert PRCustomLocal.fields.key?(:ref)
    assert_equal "ref", PRCustomLocal.field_map[:ref].to_s
  end

  def test_custom_local_and_remote_names
    assert PRCustomBoth.fields.key?(:ref)
    assert_equal "refKey", PRCustomBoth.field_map[:ref].to_s
  end

  def test_after_create_callback_registered
    # ActiveModel exposes the registered callbacks via _create_callbacks
    callbacks = PRDefault._create_callbacks.map { |cb| cb.filter.to_sym rescue cb.filter }
    assert_includes callbacks, :_assign_parse_reference!,
                    "after_create callback was registered"
  end

  def test_helper_sets_field_to_canonical_form
    obj = PRDefault.new(title: "hello")
    # Simulate post-create state: server has assigned an id
    obj.id = "abc123"
    obj.define_singleton_method(:update!) { true } # neutralize the follow-up save

    obj._assign_parse_reference!

    assert_equal "PRDefault$abc123", obj.parse_reference
  end

  def test_helper_is_idempotent_when_value_already_matches
    obj = PRDefault.new
    obj.id = "abc"
    obj.parse_reference = "PRDefault$abc"
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }

    obj._assign_parse_reference!
    assert_equal 0, save_calls, "helper must not trigger a save when value already matches"
  end

  def test_helper_skips_when_id_missing
    obj = PRDefault.new(title: "no id yet")
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }
    obj._assign_parse_reference!
    assert_nil obj.parse_reference, "no id => no value to set"
    assert_equal 0, save_calls
  end

  def test_custom_local_name_helper
    obj = PRCustomLocal.new(name: "x")
    obj.id = "xyz"
    obj.define_singleton_method(:update!) { true }
    obj._assign_ref!
    assert_equal "PRCustomLocal$xyz", obj.ref
  end

  def test_subclass_redeclaring_does_not_double_register_callback
    # Count how many _assign_parse_reference! filters are in the child's
    # create-callback chain. Should be 1, not 2 (one from parent inherit
    # + one from child redeclaration would be the bug).
    matches = PRChildRedeclares._create_callbacks.select do |cb|
      (cb.filter.to_sym rescue cb.filter) == :_assign_parse_reference!
    end
    assert_equal 1, matches.size,
                 "subclass redeclaring parse_reference must not stack a second callback"
  end

  def test_populate_parse_references_helper_populates_unset_objects
    obj = PRDefault.new(title: "hi")
    obj.id = "abc"
    obj.define_singleton_method(:update!) { true }

    updated = PRDefault.populate_parse_references!([obj])
    assert_equal "PRDefault$abc", obj.parse_reference
    assert_equal [obj], updated
  end

  def test_populate_parse_references_helper_skips_already_set
    obj = PRDefault.new
    obj.id = "abc"
    obj.parse_reference = "PRDefault$abc"
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }

    updated = PRDefault.populate_parse_references!([obj])
    assert_equal 0, save_calls, "already-populated objects must not trigger update!"
    assert_empty updated, "no objects considered updated"
  end

  def test_populate_parse_references_helper_skips_missing_id
    obj = PRDefault.new(title: "no id")
    save_calls = 0
    obj.define_singleton_method(:update!) { save_calls += 1; true }
    PRDefault.populate_parse_references!([obj])
    assert_equal 0, save_calls
  end

  def test_works_on_user_subclass
    user = PRSystemUserSub.new
    user.id = "user_abc"
    user.define_singleton_method(:update!) { true }
    user._assign_parse_reference!
    assert_equal "_User$user_abc", user.parse_reference,
                 "system-class subclasses produce the underscore-prefixed parse_class"
  end
end
