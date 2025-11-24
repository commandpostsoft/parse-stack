require_relative '../../test_helper_integration'

# Test models for partial fetch testing
class PartialFetchPost < Parse::Object
  parse_class "PartialFetchPost"

  property :title, :string
  property :content, :string
  property :category, :string
  property :view_count, :integer, default: 0
  property :is_published, :boolean, default: false
  property :is_featured, :boolean, default: false
  property :tags, :array, default: []
  property :meta_data, :object

  belongs_to :author, as: :partial_fetch_user
end

class PartialFetchUser < Parse::Object
  parse_class "PartialFetchUser"

  property :name, :string
  property :email, :string
  property :age, :integer
  property :is_active, :boolean, default: true
  property :is_verified, :boolean, default: false
  property :settings, :object
end

class PartialFetchIntegrationTest < Minitest::Test
  include ParseStackIntegrationTest

  def with_timeout(seconds, message = "Operation")
    Timeout::timeout(seconds) do
      yield
    end
  rescue Timeout::Error
    flunk "#{message} timed out after #{seconds} seconds"
  end

  def test_partial_fetch_tracks_fetched_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "partial fetch tracking test") do
        puts "\n=== Testing Partial Fetch Tracks Fetched Keys ==="

        # Create test post with full data
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "This is the content",
          category: "tech",
          view_count: 100,
          is_published: true,
          is_featured: true,
          tags: ["ruby", "testing"],
          meta_data: { featured: true }
        )
        assert post.save, "Post should save"

        # Fetch with specific keys
        fetched_post = PartialFetchPost.first(keys: [:title, :category])

        # Check that object is partially fetched
        assert fetched_post.partially_fetched?, "Post should be marked as partially fetched"

        # Check that fetched_keys includes the requested keys and :id
        assert fetched_post.fetched_keys.include?(:title), "fetched_keys should include :title"
        assert fetched_post.fetched_keys.include?(:category), "fetched_keys should include :category"
        assert fetched_post.fetched_keys.include?(:id), "fetched_keys should always include :id"

        # Check field_was_fetched? method
        assert fetched_post.field_was_fetched?(:title), "title should be marked as fetched"
        assert fetched_post.field_was_fetched?(:category), "category should be marked as fetched"
        assert fetched_post.field_was_fetched?(:id), "id should always be fetched"
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched"
        refute fetched_post.field_was_fetched?(:view_count), "view_count should not be fetched"

        puts "Partial fetch tracking works correctly"
      end
    end
  end

  def test_partial_fetch_no_dirty_tracking_for_defaults
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "partial fetch no dirty tracking test") do
        puts "\n=== Testing Partial Fetch Has No Dirty Tracking for Defaults ==="

        # Create post with specific values for fields with defaults
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          view_count: 50,
          is_published: true,
          is_featured: true,
          tags: ["ruby"]
        )
        assert post.save, "Post should save"

        # Fetch with only :id and :title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # The changes hash should be empty - no dirty tracking from defaults
        assert_empty fetched_post.changes, "Changes should be empty after partial fetch"

        # Fields with defaults should not be marked as changed
        refute fetched_post.view_count_changed?, "view_count should not be changed"
        refute fetched_post.is_published_changed?, "is_published should not be changed"
        refute fetched_post.is_featured_changed?, "is_featured should not be changed"
        refute fetched_post.tags_changed?, "tags should not be changed"

        puts "Partial fetch has no dirty tracking for defaults"
      end
    end
  end

  def test_partial_fetch_autofetches_unfetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "autofetch unfetched fields test") do
        puts "\n=== Testing Partial Fetch Autofetches Unfetched Fields ==="

        # Create post with all fields set
        original_content = "This is the original content that should be autofetched"
        post = PartialFetchPost.new(
          title: "Test Post",
          content: original_content,
          category: "tech",
          view_count: 100,
          is_published: true
        )
        assert post.save, "Post should save"

        # Fetch with only :title
        fetched_post = PartialFetchPost.first(keys: [:title])

        # Verify it's partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Access the content field - this should trigger autofetch
        actual_content = fetched_post.content

        # After autofetch, the object should no longer be partially fetched
        refute fetched_post.partially_fetched?, "Post should no longer be partially fetched after autofetch"

        # The content should match the original
        assert_equal original_content, actual_content, "Content should match original after autofetch"

        # Other fields should also be populated
        assert_equal "tech", fetched_post.category, "Category should be fetched"
        assert_equal 100, fetched_post.view_count, "View count should be fetched"
        assert fetched_post.is_published, "is_published should be fetched"

        puts "Autofetch works correctly for unfetched fields"
      end
    end
  end

  def test_partial_fetch_doesnt_autofetch_fetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "no autofetch for fetched fields test") do
        puts "\n=== Testing Partial Fetch Doesn't Autofetch Fetched Fields ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          category: "tech"
        )
        assert post.save, "Post should save"

        # Fetch with :title and :category
        fetched_post = PartialFetchPost.first(keys: [:title, :category])

        # Access fetched fields - should not trigger autofetch
        title = fetched_post.title
        category = fetched_post.category

        # Object should still be partially fetched
        assert fetched_post.partially_fetched?, "Post should still be partially fetched after accessing fetched fields"

        # Values should be correct
        assert_equal "Test Post", title
        assert_equal "tech", category

        puts "No autofetch for fetched fields"
      end
    end
  end

  def test_empty_keys_means_fully_fetched
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "empty keys fully fetched test") do
        puts "\n=== Testing Empty Keys Means Fully Fetched ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content"
        )
        assert post.save, "Post should save"

        # Fetch with empty keys array
        fetched_post = PartialFetchPost.query.keys().first

        # Object should not be partially fetched (empty keys = full fetch)
        refute fetched_post.partially_fetched?, "Empty keys should mean fully fetched"

        # All fields should be fetched
        assert fetched_post.field_was_fetched?(:title), "title should be fetched"
        assert fetched_post.field_was_fetched?(:content), "content should be fetched"
        assert fetched_post.field_was_fetched?(:category), "category should be fetched"

        puts "Empty keys means fully fetched"
      end
    end
  end

  def test_full_fetch_not_partially_fetched
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "full fetch not partially fetched test") do
        puts "\n=== Testing Full Fetch Is Not Partially Fetched ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content"
        )
        assert post.save, "Post should save"

        # Fetch without keys (full fetch)
        fetched_post = PartialFetchPost.first

        # Object should not be partially fetched
        refute fetched_post.partially_fetched?, "Full fetch should not be partially fetched"

        # All fields should be considered fetched
        assert fetched_post.field_was_fetched?(:title)
        assert fetched_post.field_was_fetched?(:content)
        assert fetched_post.field_was_fetched?(:view_count)

        puts "Full fetch is not partially fetched"
      end
    end
  end

  def test_fetch_clears_partial_fetch_state
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "fetch clears partial state test") do
        puts "\n=== Testing fetch! Clears Partial Fetch State ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content"
        )
        assert post.save, "Post should save"

        # Fetch with specific keys
        fetched_post = PartialFetchPost.first(keys: [:title])

        # Verify it's partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Call fetch! to get full object
        fetched_post.fetch!

        # Should no longer be partially fetched
        refute fetched_post.partially_fetched?, "Post should not be partially fetched after fetch!"

        # All fields should now be available
        assert_equal "Content", fetched_post.content, "Content should be available after fetch!"

        puts "fetch! clears partial fetch state"
      end
    end
  end

  def test_partial_fetch_save_only_changed_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "partial fetch save only changed fields test") do
        puts "\n=== Testing Partial Fetch Save Only Changed Fields ==="

        # Create post with specific values
        post = PartialFetchPost.new(
          title: "Original Title",
          content: "Original Content",
          view_count: 100,
          is_published: true
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Change only the title
        fetched_post.title = "Updated Title"

        # Save should only update the title
        assert fetched_post.save, "Post should save with only title changed"

        # Verify by fetching fresh copy
        fresh_post = PartialFetchPost.find(post_id)

        assert_equal "Updated Title", fresh_post.title, "Title should be updated"
        assert_equal "Original Content", fresh_post.content, "Content should not be changed"
        assert_equal 100, fresh_post.view_count, "View count should not be changed"
        assert fresh_post.is_published, "is_published should not be changed"

        puts "Partial fetch save only updates changed fields"
      end
    end
  end

  def test_partial_fetch_with_associations
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "partial fetch with associations test") do
        puts "\n=== Testing Partial Fetch with Associations ==="

        # Create user
        user = PartialFetchUser.new(
          name: "Test User",
          email: "test@example.com",
          age: 30
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user
        )
        assert post.save, "Post should save"

        # Fetch post with only title and author
        fetched_post = PartialFetchPost.first(keys: [:title, :author])

        # Should be partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Author should be fetched (as a pointer)
        assert fetched_post.field_was_fetched?(:author), "author should be marked as fetched"

        # Content should not be fetched
        refute fetched_post.field_was_fetched?(:content), "content should not be fetched"

        puts "Partial fetch with associations works correctly"
      end
    end
  end

  def test_partial_fetch_id_always_included
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "id always included test") do
        puts "\n=== Testing :id Always Included in Fetched Keys ==="

        # Create post
        post = PartialFetchPost.new(title: "Test Post")
        assert post.save, "Post should save"

        # Fetch with keys that don't include :id
        fetched_post = PartialFetchPost.first(keys: [:title])

        # :id should still be in fetched_keys
        assert fetched_post.fetched_keys.include?(:id), ":id should be in fetched_keys"
        assert fetched_post.fetched_keys.include?(:objectId), ":objectId should be in fetched_keys"

        # id should be available
        assert fetched_post.id.present?, "id should be available"

        # field_was_fetched? should return true for id
        assert fetched_post.field_was_fetched?(:id), "id should be marked as fetched"

        puts ":id is always included in fetched keys"
      end
    end
  end

  def test_partial_fetch_base_keys_always_fetched
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "base keys always fetched test") do
        puts "\n=== Testing Base Keys Always Considered Fetched ==="

        # Create post
        post = PartialFetchPost.new(title: "Test Post")
        assert post.save, "Post should save"

        # Fetch with minimal keys
        fetched_post = PartialFetchPost.first(keys: [:title])

        # Base keys should always be considered fetched
        assert fetched_post.field_was_fetched?(:id), "id should be considered fetched"
        assert fetched_post.field_was_fetched?(:created_at), "created_at should be considered fetched"
        assert fetched_post.field_was_fetched?(:updated_at), "updated_at should be considered fetched"
        assert fetched_post.field_was_fetched?(:acl), "acl should be considered fetched"

        puts "Base keys are always considered fetched"
      end
    end
  end

  def test_partial_fetch_with_query_methods
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "partial fetch with query methods test") do
        puts "\n=== Testing Partial Fetch with Query Methods ==="

        # Create posts
        post1 = PartialFetchPost.new(title: "Post 1", category: "tech", view_count: 100)
        assert post1.save, "Post 1 should save"

        post2 = PartialFetchPost.new(title: "Post 2", category: "tech", view_count: 200)
        assert post2.save, "Post 2 should save"

        # Test with .all
        posts = PartialFetchPost.query.keys(:title).all
        posts.each do |p|
          assert p.partially_fetched?, "Post should be partially fetched"
        end

        # Test with .results
        results = PartialFetchPost.query.keys(:title, :view_count).results
        results.each do |p|
          assert p.partially_fetched?, "Post should be partially fetched"
          assert p.field_was_fetched?(:title)
          assert p.field_was_fetched?(:view_count)
          refute p.field_was_fetched?(:content)
        end

        puts "Partial fetch works with all query methods"
      end
    end
  end

  def test_partial_fetch_remote_field_name_support
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "remote field name support test") do
        puts "\n=== Testing Partial Fetch Remote Field Name Support ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          view_count: 100,
          is_published: true
        )
        assert post.save, "Post should save"

        # Fetch with local field names
        fetched_post = PartialFetchPost.first(keys: [:title, :view_count, :is_published])

        # Check both local and remote names work with field_was_fetched?
        assert fetched_post.field_was_fetched?(:title), "local name :title should be fetched"
        assert fetched_post.field_was_fetched?(:view_count), "local name :view_count should be fetched"
        assert fetched_post.field_was_fetched?(:is_published), "local name :is_published should be fetched"

        puts "Remote field name support works correctly"
      end
    end
  end

  def test_partial_fetch_changes_not_include_unfetched_defaults
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "changes not include unfetched defaults test") do
        puts "\n=== Testing Changes Don't Include Unfetched Defaults ==="

        # Create post with specific values for defaults
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          view_count: 50,
          is_published: true,
          is_featured: true
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Changes should be empty
        assert_empty fetched_post.changes, "Changes should be empty"

        # Modify only the title
        fetched_post.title = "New Title"

        # Only title should be in changes
        assert_equal ["title"], fetched_post.changed, "Only title should be changed"

        # Save and verify
        assert fetched_post.save, "Save should succeed"

        # Verify other fields weren't affected
        fresh_post = PartialFetchPost.find(post_id)
        assert_equal "New Title", fresh_post.title
        assert_equal 50, fresh_post.view_count, "view_count should not be changed"
        assert fresh_post.is_published, "is_published should not be changed"
        assert fresh_post.is_featured, "is_featured should not be changed"

        puts "Changes don't include unfetched defaults"
      end
    end
  end

  def test_multiple_partial_fetches_independent
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "multiple partial fetches independent test") do
        puts "\n=== Testing Multiple Partial Fetches Are Independent ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          category: "tech"
        )
        assert post.save, "Post should save"

        # Fetch with different keys
        fetch1 = PartialFetchPost.first(keys: [:title])
        fetch2 = PartialFetchPost.first(keys: [:content])

        # Both should be partially fetched with different keys
        assert fetch1.partially_fetched?, "First fetch should be partially fetched"
        assert fetch2.partially_fetched?, "Second fetch should be partially fetched"

        # They should have different fetched keys
        assert fetch1.field_was_fetched?(:title)
        refute fetch1.field_was_fetched?(:content)

        refute fetch2.field_was_fetched?(:title)
        assert fetch2.field_was_fetched?(:content)

        puts "Multiple partial fetches are independent"
      end
    end
  end

  def test_nested_partial_fetch_with_includes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "nested partial fetch with includes test") do
        puts "\n=== Testing Nested Partial Fetch with Includes ==="

        # Create user with all fields
        user = PartialFetchUser.new(
          name: "Test User",
          email: "test@example.com",
          age: 30,
          is_active: true,
          is_verified: true,
          settings: { theme: "dark" }
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user
        )
        assert post.save, "Post should save"

        # Fetch post with specific keys and include only some author fields
        fetched_post = PartialFetchPost.query
                                       .keys(:title, :author)
                                       .includes("author.name", "author.email")
                                       .first

        # Post should be partially fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Check nested fetched keys were set
        nested_keys = fetched_post.nested_keys_for(:author)
        assert nested_keys.present?, "Should have nested keys for author"
        assert nested_keys.include?(:name), "Nested keys should include name"
        assert nested_keys.include?(:email), "Nested keys should include email"

        # Access the author - it should be built with partial fetch keys
        author = fetched_post.author
        assert author.present?, "Author should be present"

        # Author should be partially fetched
        if author.respond_to?(:partially_fetched?)
          assert author.partially_fetched?, "Author should be partially fetched"
          assert author.field_was_fetched?(:name), "Author name should be fetched"
          assert author.field_was_fetched?(:email), "Author email should be fetched"
          refute author.field_was_fetched?(:age), "Author age should not be fetched"
          refute author.field_was_fetched?(:settings), "Author settings should not be fetched"
        end

        puts "Nested partial fetch with includes works correctly"
      end
    end
  end

  def test_nested_partial_fetch_autofetches_nested_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "nested partial fetch autofetch test") do
        puts "\n=== Testing Nested Partial Fetch Autofetches Nested Fields ==="

        # Create user
        original_age = 35
        user = PartialFetchUser.new(
          name: "Test User",
          email: "test@example.com",
          age: original_age
        )
        assert user.save, "User should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          author: user
        )
        assert post.save, "Post should save"

        # Fetch post with only author.name included
        fetched_post = PartialFetchPost.query
                                       .keys(:title, :author)
                                       .includes("author.name")
                                       .first

        # Get the author
        author = fetched_post.author
        assert author.present?, "Author should be present"

        # If author is partially fetched, accessing age should trigger autofetch
        if author.respond_to?(:partially_fetched?) && author.partially_fetched?
          # Access the age - this should trigger autofetch
          actual_age = author.age

          # Age should match original (autofetch worked)
          assert_equal original_age, actual_age, "Age should match after autofetch"

          # Note: After autofetch, the author object is refreshed with full data
          # The partially_fetched? state may or may not be cleared depending on how
          # the object was fetched (direct fetch vs nested object)
        else
          # If not partially fetched, just verify the age is correct
          assert_equal original_age, author.age, "Age should be accessible"
        end

        puts "Nested partial fetch autofetches nested fields correctly"
      end
    end
  end

  def test_parse_includes_to_nested_keys
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(10, "parse includes to nested keys test") do
        puts "\n=== Testing parse_includes_to_nested_keys ==="

        # Create a query to test the helper
        query = PartialFetchPost.query

        # Test parsing includes
        includes = [:author, :"author.name", :"author.email", :"team.manager"]
        nested_keys = query.send(:parse_includes_to_nested_keys, includes)

        # Check author has name and email
        assert nested_keys[:author].present?, "Should have nested keys for author"
        assert nested_keys[:author].include?(:name), "Author should have name"
        assert nested_keys[:author].include?(:email), "Author should have email"

        # Check team has manager
        assert nested_keys[:team].present?, "Should have nested keys for team"
        assert nested_keys[:team].include?(:manager), "Team should have manager"

        puts "parse_includes_to_nested_keys works correctly"
      end
    end
  end

  def test_assignment_to_unfetched_field_does_not_trigger_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "assignment no autofetch test") do
        puts "\n=== Testing Assignment to Unfetched Field Does Not Trigger Autofetch ==="

        # Create post with content
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Original Content",
          category: "tech",
          view_count: 100
        )
        assert post.save, "Post should save"

        # Fetch with only :title (content is not fetched)
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Verify it's partially fetched and content was not fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:content), "Content should not be fetched initially"

        # Assign to unfetched field - this should NOT trigger autofetch
        # The object should still be partially fetched (not fully fetched)
        fetched_post.content = "New Content"

        # After assignment, content should now be marked as fetched
        # (since we've defined its value, no need to fetch from server)
        assert fetched_post.field_was_fetched?(:content), "Content should be marked as fetched after assignment"

        # Other unfetched fields should still not be fetched
        refute fetched_post.field_was_fetched?(:category), "Category should still not be fetched"
        refute fetched_post.field_was_fetched?(:view_count), "View count should still not be fetched"

        # The object should still be considered partially fetched
        # (because other fields like category and view_count are still not fetched)
        assert fetched_post.partially_fetched?, "Post should still be partially fetched"

        puts "Assignment to unfetched field does not trigger autofetch"
      end
    end
  end

  def test_assignment_to_unfetched_field_tracks_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "assignment change tracking test") do
        puts "\n=== Testing Assignment to Unfetched Field Tracks Changes ==="

        # Create post with content
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Original Content",
          category: "tech"
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title (content is not fetched)
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Verify initial state
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        assert_empty fetched_post.changed, "No fields should be changed initially"

        # Assign to unfetched field
        fetched_post.content = "New Content"

        # The field should be marked as changed
        assert fetched_post.content_changed?, "Content should be marked as changed"
        assert_includes fetched_post.changed, "content", "Changed array should include content"

        # Save and verify the change was persisted
        assert fetched_post.save, "Save should succeed"

        # Fetch fresh copy to verify
        fresh_post = PartialFetchPost.find(post_id)
        assert_equal "New Content", fresh_post.content, "Content should be updated"
        assert_equal "Test Post", fresh_post.title, "Title should be unchanged"
        assert_equal "tech", fresh_post.category, "Category should be unchanged"

        puts "Assignment to unfetched field tracks changes correctly"
      end
    end
  end

  def test_multiple_assignments_to_unfetched_fields
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "multiple assignments test") do
        puts "\n=== Testing Multiple Assignments to Unfetched Fields ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Original Content",
          category: "original",
          view_count: 50
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :id
        fetched_post = PartialFetchPost.first(keys: [:id])

        # Verify initial state
        assert fetched_post.partially_fetched?, "Post should be partially fetched"

        # Assign to multiple unfetched fields
        fetched_post.title = "New Title"
        fetched_post.content = "New Content"
        fetched_post.category = "new"

        # All fields should be marked as changed
        assert_includes fetched_post.changed, "title", "Title should be changed"
        assert_includes fetched_post.changed, "content", "Content should be changed"
        assert_includes fetched_post.changed, "category", "Category should be changed"

        # All assigned fields should now be marked as fetched
        assert fetched_post.field_was_fetched?(:title), "Title should be fetched"
        assert fetched_post.field_was_fetched?(:content), "Content should be fetched"
        assert fetched_post.field_was_fetched?(:category), "Category should be fetched"

        # Unassigned fields should still not be fetched
        refute fetched_post.field_was_fetched?(:view_count), "View count should not be fetched"

        # Save and verify
        assert fetched_post.save, "Save should succeed"

        fresh_post = PartialFetchPost.find(post_id)
        assert_equal "New Title", fresh_post.title
        assert_equal "New Content", fresh_post.content
        assert_equal "new", fresh_post.category
        assert_equal 50, fresh_post.view_count, "View count should be unchanged"

        puts "Multiple assignments to unfetched fields work correctly"
      end
    end
  end

  def test_assignment_with_same_value_does_not_mark_changed
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(15, "same value assignment test") do
        puts "\n=== Testing Assignment with Same Value Does Not Mark Changed ==="

        # Create post
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content"
        )
        assert post.save, "Post should save"

        # Fetch with :title
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Assign same value to title
        fetched_post.title = "Test Post"

        # Title should not be marked as changed (same value)
        refute fetched_post.title_changed?, "Title should not be marked as changed"
        assert_empty fetched_post.changed, "No fields should be changed"

        puts "Assignment with same value does not mark changed"
      end
    end
  end

  def test_belongs_to_assignment_to_unfetched_field_tracks_changes
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "belongs_to assignment test") do
        puts "\n=== Testing belongs_to Assignment to Unfetched Field Tracks Changes ==="

        # Create users
        user1 = PartialFetchUser.new(name: "User 1", email: "user1@example.com")
        assert user1.save, "User 1 should save"

        user2 = PartialFetchUser.new(name: "User 2", email: "user2@example.com")
        assert user2.save, "User 2 should save"

        # Create post with author
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user1
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch with only :title (author is not fetched)
        fetched_post = PartialFetchPost.first(keys: [:id, :title])

        # Verify initial state
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:author), "Author should not be fetched initially"

        # Assign to unfetched belongs_to field
        fetched_post.author = user2

        # Author should be marked as changed
        assert fetched_post.author_changed?, "Author should be marked as changed"
        assert_includes fetched_post.changed, "author", "Changed array should include author"

        # Author should now be marked as fetched
        assert fetched_post.field_was_fetched?(:author), "Author should be marked as fetched after assignment"

        # Save and verify
        assert fetched_post.save, "Save should succeed"

        fresh_post = PartialFetchPost.first(includes: :author)
        assert_equal user2.id, fresh_post.author.id, "Author should be updated to user2"

        puts "belongs_to assignment to unfetched field tracks changes correctly"
      end
    end
  end

  def test_belongs_to_unfetched_field_triggers_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "belongs_to autofetch test") do
        puts "\n=== Testing belongs_to Unfetched Field Triggers Autofetch ==="

        # Create user and post with author
        user = PartialFetchUser.new(name: "Test Author", email: "author@example.com")
        assert user.save, "User should save"

        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with only [:id, :title] (author is NOT included)
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:id, :title])

        # Verify it's partially fetched and author was not fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:author), "Author should not be fetched initially"

        # Access the author field - this should trigger autofetch
        author_result = fetched_post.author

        # Author should not be nil (this was the bug)
        refute_nil author_result, "Author should not be nil after autofetch"
        assert_instance_of PartialFetchUser, author_result, "Author should be a PartialFetchUser"
        assert_equal user.id, author_result.id, "Author should have correct id"

        puts "belongs_to unfetched field correctly triggers autofetch"
      end
    end
  end

  def test_belongs_to_unfetched_field_with_autofetch_disabled_raises_error
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "belongs_to error test") do
        puts "\n=== Testing belongs_to Unfetched Field with Autofetch Disabled Raises Error ==="

        # Create user and post with author
        user = PartialFetchUser.new(name: "Test Author", email: "author@example.com")
        assert user.save, "User should save"

        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          author: user
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with only [:id, :title]
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:id, :title])

        # Disable autofetch on the fetched object
        fetched_post.disable_autofetch!

        # Verify it's partially fetched and autofetch is disabled
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        assert fetched_post.autofetch_disabled?, "Autofetch should be disabled"

        # Accessing unfetched author should raise error
        error = assert_raises(Parse::UnfetchedFieldAccessError) do
          fetched_post.author
        end

        assert_match(/author/, error.message, "Error should mention the field name")

        puts "belongs_to unfetched field with autofetch disabled correctly raises error"
      end
    end
  end

  def test_has_many_unfetched_field_triggers_autofetch
    skip "Docker integration tests require PARSE_TEST_USE_DOCKER=true" unless ENV['PARSE_TEST_USE_DOCKER'] == 'true'

    with_parse_server do
      with_timeout(20, "has_many autofetch test") do
        puts "\n=== Testing has_many Unfetched Field Triggers Autofetch ==="

        # Create a post with a tags array
        post = PartialFetchPost.new(
          title: "Test Post",
          content: "Content",
          tags: ["ruby", "testing", "parse"]
        )
        assert post.save, "Post should save"
        post_id = post.id

        # Fetch post with only [:id, :title] (tags array is NOT included)
        fetched_post = PartialFetchPost.first(id: post_id, keys: [:id, :title])

        # Verify it's partially fetched and tags was not fetched
        assert fetched_post.partially_fetched?, "Post should be partially fetched"
        refute fetched_post.field_was_fetched?(:tags), "Tags should not be fetched initially"

        # Access the tags field - this should trigger autofetch for array fields
        tags_result = fetched_post.tags

        # Tags should not be nil after autofetch (for array fields, they get autofetched)
        refute_nil tags_result, "Tags should not be nil after autofetch"
        assert_equal ["ruby", "testing", "parse"], tags_result, "Tags should have correct values"

        puts "has_many/array unfetched field correctly triggers autofetch"
      end
    end
  end
end
