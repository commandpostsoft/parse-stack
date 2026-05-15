# encoding: UTF-8
# frozen_string_literal: true

require_relative "../../test_helper"

# Tests for the agent_fields / agent_usage DSL added to Parse::Object via
# Parse::Agent::MetadataDSL, plus the schema-enrichment and key-projection
# behavior that depends on them.
class AgentFieldAllowlistTest < Minitest::Test
  # Fixture model: declares both a field allowlist and a usage hint, plus
  # several noisy fields that must NOT surface to the agent.
  class FixtureTeam < Parse::Object
    parse_class "FixtureTeam"

    agent_description "A workspace grouping users on a project"
    agent_usage <<~USAGE
      `status` values: "active" | "archived" | "frozen".
      `member_count` is denormalized; recompute via _User pointer.
    USAGE
    agent_fields :name, :status, :member_count

    property :name, :string
    property :status, :string
    property :member_count, :integer
    property :legacy_settings_blob, :object
    property :sync_token, :string
  end

  # Fixture with no agent_fields declaration — should not be filtered.
  class FixtureUnfiltered < Parse::Object
    parse_class "FixtureUnfiltered"
    agent_description "Class without an allowlist"
    property :foo, :string
    property :bar, :integer
  end

  # ============================================================
  # DSL: agent_fields
  # ============================================================

  def test_agent_fields_stores_allowlist_as_symbols
    assert_equal %i[name status member_count], FixtureTeam.agent_field_allowlist
  end

  def test_agent_fields_returns_empty_when_undeclared
    assert_equal [], FixtureUnfiltered.agent_field_allowlist
  end

  class FixtureCoerce < Parse::Object
    parse_class "FixtureCoerce"
    agent_fields "alpha", :beta
  end

  def test_agent_fields_accepts_strings_and_normalizes_to_symbols
    assert_equal %i[alpha beta], FixtureCoerce.agent_field_allowlist
  end

  def test_agent_fields_allowlist_is_frozen
    assert_predicate FixtureTeam.agent_field_allowlist, :frozen?
  end

  # ============================================================
  # DSL: agent_usage
  # ============================================================

  def test_agent_usage_stores_text
    refute_nil FixtureTeam.agent_usage
    assert_match(/status.*values/, FixtureTeam.agent_usage)
  end

  def test_agent_usage_returns_nil_when_undeclared
    assert_nil FixtureUnfiltered.agent_usage
  end

  class FixtureUsage < Parse::Object
    parse_class "FixtureUsage"
    agent_usage "   hello   \n"
  end

  def test_agent_usage_strips_whitespace_and_freezes
    assert_equal "hello", FixtureUsage.agent_usage
    assert_predicate FixtureUsage.agent_usage, :frozen?
  end

  # ============================================================
  # has_agent_metadata? / agent_metadata
  # ============================================================

  class FixtureHasFields < Parse::Object
    parse_class "FixtureHasFields"
    agent_fields :only_field
  end

  class FixtureHasUsage < Parse::Object
    parse_class "FixtureHasUsage"
    agent_usage "hint"
  end

  def test_has_agent_metadata_includes_allowlist_and_usage
    assert FixtureHasFields.has_agent_metadata?, "agent_fields declaration alone should mark metadata as present"
    assert FixtureHasUsage.has_agent_metadata?, "agent_usage declaration alone should mark metadata as present"
  end

  def test_agent_metadata_serializes_field_allowlist_and_usage
    meta = FixtureTeam.agent_metadata
    assert_equal %i[name status member_count], meta[:field_allowlist]
    assert_match(/status.*values/, meta[:usage])
  end

  # ============================================================
  # MetadataRegistry.enriched_schema field filtering
  # ============================================================

  def test_enriched_schema_filters_fields_to_allowlist_plus_system_fields
    server_schema = {
      "className" => "FixtureTeam",
      "fields" => {
        "objectId" => { "type" => "String" },
        "createdAt" => { "type" => "Date" },
        "updatedAt" => { "type" => "Date" },
        "ACL" => { "type" => "ACL" },
        "name" => { "type" => "String" },
        "status" => { "type" => "String" },
        "member_count" => { "type" => "Number" },
        "legacy_settings_blob" => { "type" => "Object" },
        "sync_token" => { "type" => "String" },
      },
    }

    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureTeam", server_schema)
    expected_keys = %w[objectId createdAt updatedAt name status member_count].sort
    assert_equal expected_keys, result["fields"].keys.sort
    refute result["fields"].key?("ACL"), "ACL must not pass through allowlist"
    refute result["fields"].key?("legacy_settings_blob"), "non-allowlisted columns must be filtered"
  end

  def test_enriched_schema_strips_noisy_per_field_metadata
    server_schema = {
      "className" => "FixtureTeam",
      "fields" => {
        "name" => { "type" => "String", "indexed" => true, "required" => true, "defaultValue" => "" },
        "status" => { "type" => "String", "defaultValue" => "active" },
      },
    }

    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureTeam", server_schema)
    refute result["fields"]["name"].key?("indexed"), "indexed metadata must be stripped"
    refute result["fields"]["name"].key?("defaultValue"), "empty-string defaultValue must be stripped"
    assert_equal true, result["fields"]["name"]["required"]
    assert_equal "active", result["fields"]["status"]["defaultValue"], "meaningful defaultValue is kept"
  end

  def test_enriched_schema_surfaces_usage
    server_schema = { "className" => "FixtureTeam", "fields" => {} }
    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureTeam", server_schema)
    assert_match(/status.*values/, result["usage"])
  end

  def test_enriched_schema_unfiltered_class_passes_all_fields_through
    server_schema = {
      "className" => "FixtureUnfiltered",
      "fields" => {
        "objectId" => { "type" => "String" },
        "ACL" => { "type" => "ACL" },
        "foo" => { "type" => "String" },
        "bar" => { "type" => "Number" },
      },
    }
    result = Parse::Agent::MetadataRegistry.enriched_schema("FixtureUnfiltered", server_schema)
    assert result["fields"].key?("ACL"), "no allowlist means no filtering"
    assert result["fields"].key?("foo")
    assert result["fields"].key?("bar")
  end

  # ============================================================
  # MetadataRegistry.field_allowlist (used by Tools to push keys server-side)
  # ============================================================

  def test_field_allowlist_returns_strings_with_system_fields
    allowlist = Parse::Agent::MetadataRegistry.field_allowlist("FixtureTeam")
    %w[name status member_count objectId createdAt updatedAt].each do |f|
      assert_includes allowlist, f
    end
  end

  def test_field_allowlist_returns_nil_for_unfiltered_class
    assert_nil Parse::Agent::MetadataRegistry.field_allowlist("FixtureUnfiltered")
  end

  def test_field_allowlist_returns_nil_for_unknown_class
    assert_nil Parse::Agent::MetadataRegistry.field_allowlist("NoSuchClassAnywhere")
  end
end
