require_relative "../../test_helper"

class TestEqualsLinkedPointer < Minitest::Test
  extend Minitest::Spec::DSL

  def test_equals_linked_pointer_constraint_exists
    # Test that the constraint is properly registered
    operation = :author.equals_linked_pointer({ through: :project, field: :owner })
    assert_instance_of Parse::Constraint::PointerEqualsLinkedPointerConstraint, operation
    # The constraint is returned directly for equals_linked_pointer
  end

  def test_constraint_build_with_valid_parameters
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author, 
      { through: :project, field: :owner }
    )
    
    result = constraint.build
    
    # Should return aggregation pipeline marker
    assert result.key?("__aggregation_pipeline")
    
    pipeline = result["__aggregation_pipeline"]
    assert_instance_of Array, pipeline
    assert_equal 2, pipeline.length
    
    # Check $lookup stage
    lookup_stage = pipeline[0]
    assert lookup_stage.key?("$lookup")
    assert_equal "Project", lookup_stage["$lookup"]["from"]
    assert_equal "project", lookup_stage["$lookup"]["localField"]
    assert_equal "_id", lookup_stage["$lookup"]["foreignField"]
    assert_equal "project_data", lookup_stage["$lookup"]["as"]
    
    # Check $match stage with $expr
    match_stage = pipeline[1]
    assert match_stage.key?("$match")
    assert match_stage["$match"].key?("$expr")
    
    expr = match_stage["$match"]["$expr"]
    assert expr.key?("$eq")
    assert_equal 2, expr["$eq"].length
    assert_equal({ "$arrayElemAt" => ["$project_data.owner", 0] }, expr["$eq"][0])
    assert_equal "$author", expr["$eq"][1]
  end

  def test_constraint_build_with_snake_case_fields
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author_user, 
      { through: :project_data, field: :owner_user }
    )
    
    result = constraint.build
    pipeline = result["__aggregation_pipeline"]
    
    # Check field formatting (snake_case -> camelCase)
    lookup_stage = pipeline[0]
    assert_equal "ProjectDatum", lookup_stage["$lookup"]["from"]  # Rails pluralization: data -> datum
    assert_equal "projectData", lookup_stage["$lookup"]["localField"]
    assert_equal "projectData_data", lookup_stage["$lookup"]["as"]
    
    match_stage = pipeline[1]
    expr = match_stage["$match"]["$expr"]
    assert_equal({ "$arrayElemAt" => ["$projectData_data.ownerUser", 0] }, expr["$eq"][0])
    assert_equal "$authorUser", expr["$eq"][1]
  end

  def test_constraint_validation_missing_through
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      { field: :owner }
    )
    
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_constraint_validation_missing_field
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      { through: :project }
    )
    
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_constraint_validation_invalid_value
    constraint = Parse::Constraint::PointerEqualsLinkedPointerConstraint.new(
      :author,
      "invalid"
    )
    
    assert_raises(ArgumentError) do
      constraint.build
    end
  end

  def test_query_requires_aggregation_pipeline_detection
    query = Parse::Query.new("ObjectA")
    
    # Initially should not require pipeline
    refute query.requires_aggregation_pipeline?
    
    # Add equals_linked_pointer constraint
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })
    
    # Debug: check the compiled where clause structure
    compiled_where = query.compile_where
    # puts "Compiled where: #{compiled_where.inspect}"
    
    # Now should require pipeline
    assert query.requires_aggregation_pipeline?
  end

  def test_query_build_aggregation_pipeline
    query = Parse::Query.new("ObjectA")
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })
    
    pipeline = query.build_aggregation_pipeline
    
    assert_instance_of Array, pipeline
    assert_equal 2, pipeline.length
    
    # Should contain the lookup and match stages
    lookup_stage = pipeline[0]
    assert lookup_stage.key?("$lookup")
    
    match_stage = pipeline[1]
    assert match_stage.key?("$match")
    assert match_stage["$match"].key?("$expr")
  end

  def test_query_build_aggregation_pipeline_with_regular_constraints
    query = Parse::Query.new("ObjectA")
    query.where(:status => "active")
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })
    
    pipeline = query.build_aggregation_pipeline
    
    assert_instance_of Array, pipeline
    assert_equal 3, pipeline.length
    
    # Should have initial $match for regular constraints
    initial_match = pipeline[0]
    assert initial_match.key?("$match")
    assert_equal "active", initial_match["$match"]["status"]
    
    # Then lookup and expr match
    lookup_stage = pipeline[1]
    assert lookup_stage.key?("$lookup")
    
    expr_match_stage = pipeline[2]
    assert expr_match_stage.key?("$match")
    assert expr_match_stage["$match"].key?("$expr")
  end

  def test_query_build_aggregation_pipeline_with_limit_and_skip
    query = Parse::Query.new("ObjectA")
    query.where(:author.equals_linked_pointer => { through: :project, field: :owner })
    query.limit(10)
    query.skip(5)
    
    pipeline = query.build_aggregation_pipeline
    
    # Should include limit and skip stages
    assert pipeline.any? { |stage| stage.key?("$limit") && stage["$limit"] == 10 }
    assert pipeline.any? { |stage| stage.key?("$skip") && stage["$skip"] == 5 }
  end
end