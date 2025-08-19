require_relative '../../test_helper_integration'

class ACLConstraintsIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def setup
    super
    @test_users = []
    @test_roles = []
    @test_documents = []
  end

  def create_test_role(name)
    role = Parse::Role.new(name: name)
    assert role.save, "Should save role #{name}"
    @test_roles << role
    role
  end

  def create_test_document(attributes = {})
    doc = Parse::Object.new(attributes.merge('className' => 'Document'))
    assert doc.save, "Should save document"
    @test_documents << doc
    doc
  end

  def test_readable_by_role_constraint_integration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "readable_by role constraint test") do
        puts "\n=== Testing readable_by Role Constraint Integration ==="

        # Create test roles
        admin_role = create_test_role("Admin")
        editor_role = create_test_role("Editor")
        viewer_role = create_test_role("Viewer")

        # Create documents with different ACL permissions
        
        # Document 1: Admin and Editor can read
        doc1 = create_test_document(title: "Admin and Editor Doc", content: "Test content 1")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role("Admin", read: true, write: true)
        doc1.acl.apply_role("Editor", read: true, write: false)
        doc1.acl.apply(:public, read: false, write: false)  # No public access
        assert doc1.save, "Should save doc1 with ACL"

        # Document 2: Only Admin can read
        doc2 = create_test_document(title: "Admin Only Doc", content: "Test content 2")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply_role("Admin", read: true, write: true)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with ACL"

        # Document 3: Public read access
        doc3 = create_test_document(title: "Public Doc", content: "Test content 3")
        doc3.acl = Parse::ACL.new
        doc3.acl.apply(:public, read: true, write: false)
        assert doc3.save, "Should save doc3 with ACL"

        # Test readable_by Admin role - should find doc1, doc2
        query_admin = Parse::Query.new("Document")
        query_admin.readable_by("Admin")
        admin_results = query_admin.results
        
        admin_titles = admin_results.map { |doc| doc["title"] }.sort
        expected_admin_titles = ["Admin and Editor Doc", "Admin Only Doc"].sort
        assert_equal expected_admin_titles, admin_titles, "Admin should read docs 1 and 2"

        # Test readable_by Editor role - should find doc1 only
        query_editor = Parse::Query.new("Document")
        query_editor.readable_by("Editor")
        editor_results = query_editor.results
        
        editor_titles = editor_results.map { |doc| doc["title"] }
        assert_equal ["Admin and Editor Doc"], editor_titles, "Editor should read only doc 1"

        # Test readable_by Viewer role - should find nothing (no explicit permissions)
        query_viewer = Parse::Query.new("Document")
        query_viewer.readable_by("Viewer")
        viewer_results = query_viewer.results
        
        assert_equal 0, viewer_results.size, "Viewer should read no documents"

        # Test readable_by with role prefix
        query_admin_prefix = Parse::Query.new("Document")
        query_admin_prefix.readable_by("role:Admin")
        admin_prefix_results = query_admin_prefix.results
        
        admin_prefix_titles = admin_prefix_results.map { |doc| doc["title"] }.sort
        assert_equal expected_admin_titles, admin_prefix_titles, "role:Admin prefix should work the same"

        puts "✅ readable_by role constraint integration test passed"
      end
    end
  end

  def test_writable_by_role_constraint_integration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "writable_by role constraint test") do
        puts "\n=== Testing writable_by Role Constraint Integration ==="

        # Create test roles
        admin_role = create_test_role("Admin")
        editor_role = create_test_role("Editor")

        # Create documents with different write permissions
        
        # Document 1: Admin and Editor can write
        doc1 = create_test_document(title: "Admin and Editor Writable", content: "Content 1")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role("Admin", read: true, write: true)
        doc1.acl.apply_role("Editor", read: true, write: true)
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save doc1 with ACL"

        # Document 2: Only Admin can write (Editor can read)
        doc2 = create_test_document(title: "Admin Write Only", content: "Content 2")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply_role("Admin", read: true, write: true)
        doc2.acl.apply_role("Editor", read: true, write: false)  # Read but not write
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with ACL"

        # Document 3: Public write access (unusual but valid)
        doc3 = create_test_document(title: "Public Writable", content: "Content 3")
        doc3.acl = Parse::ACL.new
        doc3.acl.apply(:public, read: true, write: true)
        assert doc3.save, "Should save doc3 with ACL"

        # Test writable_by Admin role - should find doc1, doc2
        query_admin = Parse::Query.new("Document")
        query_admin.writable_by("Admin")
        admin_results = query_admin.results
        
        admin_titles = admin_results.map { |doc| doc["title"] }.sort
        expected_admin_titles = ["Admin and Editor Writable", "Admin Write Only"].sort
        assert_equal expected_admin_titles, admin_titles, "Admin should write to docs 1 and 2"

        # Test writable_by Editor role - should find doc1 only
        query_editor = Parse::Query.new("Document")
        query_editor.writable_by("Editor")
        editor_results = query_editor.results
        
        editor_titles = editor_results.map { |doc| doc["title"] }
        assert_equal ["Admin and Editor Writable"], editor_titles, "Editor should write only to doc 1"

        puts "✅ writable_by role constraint integration test passed"
      end
    end
  end

  def test_readable_by_user_constraint_integration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "readable_by user constraint test") do
        puts "\n=== Testing readable_by User Constraint Integration ==="

        # Create test users
        user1 = create_test_user(username: "testuser1", password: "password123")
        user2 = create_test_user(username: "testuser2", password: "password123")

        # Create documents with user-specific permissions
        
        # Document 1: Only user1 can read
        doc1 = create_test_document(title: "User1 Private Doc", content: "Private content")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply(user1.id, read: true, write: true)
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save doc1 with user ACL"

        # Document 2: Both users can read
        doc2 = create_test_document(title: "Shared Doc", content: "Shared content")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply(user1.id, read: true, write: true)
        doc2.acl.apply(user2.id, read: true, write: false)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with user ACLs"

        # Test readable_by user1 - should find doc1, doc2
        query_user1 = Parse::Query.new("Document")
        query_user1.readable_by(user1)
        user1_results = query_user1.results
        
        user1_titles = user1_results.map { |doc| doc["title"] }.sort
        expected_user1_titles = ["User1 Private Doc", "Shared Doc"].sort
        assert_equal expected_user1_titles, user1_titles, "User1 should read both documents"

        # Test readable_by user2 - should find doc2 only
        query_user2 = Parse::Query.new("Document")
        query_user2.readable_by(user2)
        user2_results = query_user2.results
        
        user2_titles = user2_results.map { |doc| doc["title"] }
        assert_equal ["Shared Doc"], user2_titles, "User2 should read only shared doc"

        # Test readable_by user ID string
        query_user1_id = Parse::Query.new("Document")
        query_user1_id.readable_by(user1.id)
        user1_id_results = query_user1_id.results
        
        user1_id_titles = user1_id_results.map { |doc| doc["title"] }.sort
        assert_equal expected_user1_titles, user1_id_titles, "User1 ID string should work the same"

        puts "✅ readable_by user constraint integration test passed"
      end
    end
  end

  def test_writable_by_user_constraint_integration
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "writable_by user constraint test") do
        puts "\n=== Testing writable_by User Constraint Integration ==="

        # Create test users
        user1 = create_test_user(username: "writeuser1", password: "password123")
        user2 = create_test_user(username: "writeuser2", password: "password123")

        # Create documents with different write permissions
        
        # Document 1: Only user1 can write
        doc1 = create_test_document(title: "User1 Writable", content: "Content 1")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply(user1.id, read: true, write: true)
        doc1.acl.apply(user2.id, read: true, write: false)  # User2 can read but not write
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save doc1 with user ACLs"

        # Document 2: Both users can write
        doc2 = create_test_document(title: "Both Users Writable", content: "Content 2")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply(user1.id, read: true, write: true)
        doc2.acl.apply(user2.id, read: true, write: true)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save doc2 with user ACLs"

        # Test writable_by user1 - should find both documents
        query_user1 = Parse::Query.new("Document")
        query_user1.writable_by(user1)
        user1_results = query_user1.results
        
        user1_titles = user1_results.map { |doc| doc["title"] }.sort
        expected_user1_titles = ["User1 Writable", "Both Users Writable"].sort
        assert_equal expected_user1_titles, user1_titles, "User1 should write to both documents"

        # Test writable_by user2 - should find doc2 only
        query_user2 = Parse::Query.new("Document")
        query_user2.writable_by(user2)
        user2_results = query_user2.results
        
        user2_titles = user2_results.map { |doc| doc["title"] }
        assert_equal ["Both Users Writable"], user2_titles, "User2 should write only to shared doc"

        puts "✅ writable_by user constraint integration test passed"
      end
    end
  end

  def test_mixed_readable_writable_constraints
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(25, "mixed readable/writable constraints test") do
        puts "\n=== Testing Mixed readable_by and writable_by Constraints ==="

        # Create test data
        admin_role = create_test_role("Admin")
        user1 = create_test_user(username: "mixeduser1", password: "password123")

        # Document with complex ACL
        doc1 = create_test_document(title: "Complex ACL Doc", content: "Complex content")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role("Admin", read: true, write: true)  # Admin: read/write
        doc1.acl.apply(user1.id, read: true, write: false)    # User1: read only
        doc1.acl.apply(:public, read: false, write: false)    # No public access
        assert doc1.save, "Should save complex ACL document"

        # Test compound query: readable_by user1 AND writable_by Admin
        query_complex = Parse::Query.new("Document")
        query_complex.readable_by(user1.id)
        query_complex.writable_by("Admin")
        
        complex_results = query_complex.results
        assert_equal 1, complex_results.size, "Should find 1 document matching both constraints"
        assert_equal "Complex ACL Doc", complex_results.first["title"], "Should find the complex ACL document"

        # Test query that should return no results: writable_by user1
        query_no_results = Parse::Query.new("Document")
        query_no_results.writable_by(user1.id)
        
        no_results = query_no_results.results
        assert_equal 0, no_results.size, "User1 should not be able to write to any documents"

        puts "✅ Mixed readable/writable constraints test passed"
      end
    end
  end

  def test_acl_constraints_with_arrays
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "ACL constraints with arrays test") do
        puts "\n=== Testing ACL Constraints with Arrays ==="

        # Create test roles
        admin_role = create_test_role("Admin")
        editor_role = create_test_role("Editor")
        viewer_role = create_test_role("Viewer")

        # Create documents with role-based access
        doc1 = create_test_document(title: "Admin Doc", content: "Admin content")
        doc1.acl = Parse::ACL.new
        doc1.acl.apply_role("Admin", read: true, write: true)
        doc1.acl.apply(:public, read: false, write: false)
        assert doc1.save, "Should save admin doc"

        doc2 = create_test_document(title: "Editor Doc", content: "Editor content")
        doc2.acl = Parse::ACL.new
        doc2.acl.apply_role("Editor", read: true, write: true)
        doc2.acl.apply(:public, read: false, write: false)
        assert doc2.save, "Should save editor doc"

        # Test readable_by with array of roles
        query_multiple = Parse::Query.new("Document")
        query_multiple.readable_by(["Admin", "Editor"])
        
        multiple_results = query_multiple.results
        assert_equal 2, multiple_results.size, "Should find documents for both roles"
        
        multiple_titles = multiple_results.map { |doc| doc["title"] }.sort
        expected_titles = ["Admin Doc", "Editor Doc"].sort
        assert_equal expected_titles, multiple_titles, "Should find documents for both Admin and Editor"

        puts "✅ ACL constraints with arrays test passed"
      end
    end
  end
end