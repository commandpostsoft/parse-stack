require_relative 'test_helper'
require_relative 'support/docker_helper'
require_relative 'support/test_server'

# Integration test helper that can work with a real Parse Server
module ParseStackIntegrationTest
  def self.included(base)
    base.class_eval do
      # Start Docker containers before all tests if configured
      if ENV['PARSE_TEST_USE_DOCKER'] == 'true'
        Parse::Test::DockerHelper.ensure_available!
        Parse::Test::DockerHelper.start!
        Parse::Test::DockerHelper.setup_exit_handler
      end

      # Setup Parse connection
      setup do
        @test_context = Parse::Test::Context.new
        Parse::Test::ServerHelper.setup
      end

      # Cleanup after each test
      teardown do
        @test_context.cleanup! if @test_context
      end
    end
  end

  # Helper methods available in tests
  def with_parse_server(&block)
    Parse::Test::ServerHelper.with_server(&block)
  end

  def create_test_object(class_name, attributes = {})
    obj = Parse::Object.new(attributes.merge('className' => class_name))
    obj.save
    @test_context.track(obj)
    obj
  end

  def create_test_user(attributes = {})
    user = Parse::Test::ServerHelper.create_test_user(**attributes)
    @test_context.track(user)
    user
  end

  def reset_database!
    Parse::Test::ServerHelper.reset_database!
  end
end

# Example usage in tests:
# class MyIntegrationTest < Minitest::Test
#   include ParseStackIntegrationTest
#
#   def test_something_with_real_server
#     with_parse_server do
#       user = create_test_user(username: 'testuser')
#       assert user.id.present?
#     end
#   end
# end