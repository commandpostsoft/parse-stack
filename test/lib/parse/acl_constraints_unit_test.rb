require_relative '../../test_helper'

class ACLConstraintsUnitTest < Minitest::Test

  def test_readable_by_constraint_generates_aggregation_pipeline
    puts "\n=== Testing ACL readable_by Constraint Generation ==="

    # Test single string - readable_by uses strings as-is (user IDs, role names with prefix, or "*")
    query = Parse::Query.new("Post")
    query.readable_by("role:Admin")  # Explicit role prefix

    # Should generate aggregation pipeline with simple $in query
    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$in" => ["role:Admin"] }
        }
      }
    ]

    assert_equal expected_pipeline, pipeline, "Should generate aggregation pipeline for ACL constraints"
    puts "✅ Single role constraint generates pipeline: #{pipeline.inspect}"

    # Test multiple values (mix of user IDs and role names)
    query2 = Parse::Query.new("Post")
    query2.readable_by(["user123", "role:Editor"])

    pipeline2 = query2.pipeline
    expected_pipeline2 = [
      {
        "$match" => {
          "_rperm" => { "$in" => ["user123", "role:Editor"] }
        }
      }
    ]

    assert_equal expected_pipeline2, pipeline2, "Should generate aggregation pipeline for mixed values"
    puts "✅ Multiple values constraint generates pipeline: #{pipeline2.inspect}"
  end

  def test_writable_by_constraint_generates_aggregation_pipeline
    puts "\n=== Testing ACL writable_by Constraint Generation ==="

    # Test single string - writable_by uses strings as-is
    query = Parse::Query.new("Post")
    query.writable_by("role:Admin")  # Explicit role prefix

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_wperm" => { "$in" => ["role:Admin"] }
        }
      }
    ]

    assert_equal expected_pipeline, pipeline, "Should generate aggregation pipeline for writable constraint"
    puts "✅ Single role writable constraint generates pipeline: #{pipeline.inspect}"

    # Test multiple values
    query2 = Parse::Query.new("Post")
    query2.writable_by(["user123", "role:Editor"])

    pipeline2 = query2.pipeline
    expected_pipeline2 = [
      {
        "$match" => {
          "_wperm" => { "$in" => ["user123", "role:Editor"] }
        }
      }
    ]

    assert_equal expected_pipeline2, pipeline2, "Should generate aggregation pipeline for multiple writable values"
    puts "✅ Multiple values writable constraint generates pipeline: #{pipeline2.inspect}"
  end

  def test_pipeline_method_returns_stages_for_acl_constraints
    puts "\n=== Testing Pipeline Method ==="

    # ACL constraints use aggregation pipelines to access _rperm/_wperm fields
    query = Parse::Query.new("Post")
    query.readable_by("role:Admin")  # Use explicit role prefix

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$in" => ["role:Admin"] }
        }
      }
    ]

    assert_equal expected_pipeline, pipeline, "ACL constraints should generate aggregation pipelines"
    assert query.requires_aggregation?, "Query should require aggregation"
    puts "✅ Pipeline method returns aggregation stages for ACL constraints"
    puts "Pipeline: #{pipeline.inspect}"
  end

  def test_constraint_chaining_with_acl
    puts "\n=== Testing ACL Constraint Chaining ==="

    # Test chaining ACL constraints with other constraints
    query = Parse::Query.new("Post")
    query.where(:title.in => ["Post 1", "Post 2"])
    query.readable_by("Admin")
    query.where(:published => true)

    compiled = query.compile
    puts "✅ Chained constraints: #{compiled[:where]}"

    # Should contain both regular constraints and ACL constraint
    assert compiled[:where].include?("_rperm"), "Should include _rperm constraint"
    assert compiled[:where].include?('"published":true'), "Should include regular constraints"
    assert compiled[:where].include?('"title":{"$in":["Post 1","Post 2"]}'), "Should include in constraint"
  end

  def test_readable_by_public_asterisk
    puts "\n=== Testing readable_by with '*' (public access) ==="

    query = Parse::Query.new("Post")
    query.readable_by("*")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$in" => ["*"] }
        }
      }
    ]

    assert_equal expected_pipeline, pipeline, "Should generate pipeline for public access"
    puts "✅ readable_by('*') generates correct pipeline"
  end

  def test_readable_by_public_alias
    puts "\n=== Testing readable_by with 'public' alias ==="

    query = Parse::Query.new("Post")
    query.readable_by("public")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_rperm" => { "$in" => ["*"] }
        }
      }
    ]

    # "public" should be converted to "*"
    assert_equal expected_pipeline, pipeline, "Should convert 'public' to '*'"
    puts "✅ readable_by('public') generates correct pipeline"
  end

  def test_writable_by_public_asterisk
    puts "\n=== Testing writable_by with '*' (public access) ==="

    query = Parse::Query.new("Post")
    query.writable_by("*")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_wperm" => { "$in" => ["*"] }
        }
      }
    ]

    assert_equal expected_pipeline, pipeline, "Should generate pipeline for public write access"
    puts "✅ writable_by('*') generates correct pipeline"
  end

  def test_writable_by_public_alias
    puts "\n=== Testing writable_by with 'public' alias ==="

    query = Parse::Query.new("Post")
    query.writable_by("public")

    pipeline = query.pipeline
    expected_pipeline = [
      {
        "$match" => {
          "_wperm" => { "$in" => ["*"] }
        }
      }
    ]

    assert_equal expected_pipeline, pipeline, "Should convert 'public' to '*' for write"
    puts "✅ writable_by('public') generates correct pipeline"
  end

end
