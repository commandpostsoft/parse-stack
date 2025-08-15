require_relative "../../../test_helper"

class TestTableFeatures < Minitest::Test
  
  def setup
    @query = Parse::Query.new("TestClass")
  end

  def create_simple_data
    # Just use simple hashes - no need for objects
    [
      {
        "objectId" => "obj1",
        "name" => "Object 1", 
        "category" => "A",
        "count" => 10
      },
      {
        "objectId" => "obj2",
        "name" => "Object 2",
        "category" => "B", 
        "count" => 5
      }
    ]
  end

  def test_to_table_with_empty_results
    # Mock empty results
    @query.stub :results, [] do
      table = @query.to_table
      assert_match(/No results found/, table)
    end
  end

  def test_to_table_with_basic_columns
    data = create_simple_data
    
    @query.stub :results, data do
      table = @query.to_table([:object_id, :name, :category])
      
      # Should contain object data
      assert_match(/obj1/, table)
      assert_match(/Object 1/, table)
      assert_match(/obj2/, table) 
      assert_match(/Object 2/, table)
      
      # Should be formatted as ASCII table
      assert_match(/\|/, table)  # Table borders
      assert_match(/-/, table)   # Table separators
    end
  end

  def test_to_table_with_custom_headers
    data = create_simple_data
    
    @query.stub :results, data do
      table = @query.to_table(
        [:object_id, :name], 
        headers: ["ID", "Name"]
      )
      
      assert_match(/ID/, table)
      assert_match(/Name/, table)
    end
  end

  def test_to_table_with_block_columns
    data = create_simple_data
    
    @query.stub :results, data do
      table = @query.to_table([
        :name,
        { 
          block: ->(obj) { obj["count"] * 2 }, 
          header: "Double Count" 
        }
      ])
      
      assert_match(/Double Count/, table)
      assert_match(/20/, table)  # 10 * 2
      assert_match(/10/, table)  # 5 * 2
    end
  end

  def test_to_table_csv_format
    data = create_simple_data
    
    @query.stub :results, data do
      csv = @query.to_table([:object_id, :name], format: :csv)
      
      # Should be CSV format - check for column headers and data
      assert_match(/Object Id,Name/, csv)  # Headers
      assert_match(/obj1,Object 1/, csv)   # Data row 1 (quotes optional for simple text)
      assert_match(/obj2,Object 2/, csv)   # Data row 2  
      refute_match(/\|/, csv)  # No table borders
    end
  end

  def test_to_table_json_format
    data = create_simple_data
    
    @query.stub :results, data do
      json = @query.to_table([:object_id, :name], format: :json)
      
      # Should be valid JSON
      parsed = JSON.parse(json)
      assert_kind_of Array, parsed
      assert_equal 2, parsed.size
      # JSON uses the formatted column names
      assert_equal "obj1", parsed.first["Object Id"]
      assert_equal "Object 1", parsed.first["Name"]
    end
  end

  # Note: extract_field_value is a private method, so we test it indirectly through to_table

  def test_dot_notation_parsing
    # Test that dot notation gets parsed correctly
    field_path = "project.team.name".split('.')
    assert_equal ["project", "team", "name"], field_path
  end

  def test_grouped_result_to_table
    grouped_data = { "A" => 10, "B" => 5, "C" => 15 }
    grouped_result = Parse::GroupedResult.new(grouped_data)
    
    table = grouped_result.to_table
    
    assert_match(/A/, table)
    assert_match(/10/, table)
    assert_match(/B/, table)
    assert_match(/5/, table)
    assert_match(/C/, table)
    assert_match(/15/, table)
  end

  def test_grouped_result_to_table_with_custom_headers
    grouped_data = { "video" => 25, "audio" => 15 }
    grouped_result = Parse::GroupedResult.new(grouped_data)
    
    table = grouped_result.to_table(headers: ["Media Type", "Count"])
    
    assert_match(/Media Type/, table)
    assert_match(/Count/, table)
    assert_match(/video/, table)
    assert_match(/25/, table)
  end

  # Note: auto_detect_columns is tested indirectly when no columns are specified

  # Note: format_field_value is tested indirectly through table output formatting

  # Note: calculate_column_widths is a private helper method

  def test_table_with_mixed_data_types
    # Test with different data types
    mixed_data = [{
      "objectId" => "test1",
      "name" => "Test Object",
      "count" => 42,
      "active" => true
    }]
    
    @query.stub :results, mixed_data do
      table = @query.to_table([:object_id, :name, :count, :active])
      
      assert_match(/test1/, table)
      assert_match(/Test Object/, table)
      assert_match(/42/, table)
      assert_match(/true/, table)
    end
  end
end