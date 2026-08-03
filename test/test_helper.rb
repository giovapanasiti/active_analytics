# Configure Rails Environment
ENV["RAILS_ENV"] = "test"

require_relative "../test/dummy/config/environment"
# The dummy app's config.paths["db/migrate"] already includes the engine's migrations
# (see test/dummy/config/application.rb), so run them directly. maintain_test_schema is
# disabled in the test environment to keep the schema loader from seeing them twice.
migration_paths = Rails.application.config.paths["db/migrate"].to_a.uniq
ActiveRecord::MigrationContext.new(migration_paths).migrate

require "rails/test_help"

# Load fixtures from the engine
if ActiveSupport::TestCase.respond_to?(:fixture_paths=)
  ActiveSupport::TestCase.fixture_paths = [ File.expand_path("fixtures", __dir__) ]
  ActionDispatch::IntegrationTest.fixture_paths = ActiveSupport::TestCase.fixture_paths
  ActiveSupport::TestCase.file_fixture_path = File.expand_path("fixtures", __dir__) + "/files"
  ActiveSupport::TestCase.fixtures :all
end
