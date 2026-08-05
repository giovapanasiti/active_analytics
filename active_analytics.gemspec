require_relative "lib/active_analytics/version"

Gem::Specification.new do |spec|
  spec.name        = "active_analytics"
  spec.version     = ActiveAnalytics::VERSION
  spec.authors     = [ "Giovanni Panasiti" ]
  spec.email       = [ "giova.panasiti@gmail.com" ]
  spec.homepage    = "https://github.com/giovapanasiti/active_analytics"
  spec.summary     = "Self-hosted session recording and behavior analytics engine for Rails (Hotjar alternative)"
  spec.description = "Records user sessions, replays them in a built-in dashboard, and surfaces AI-assisted " \
                      "behavior insights, all self-hosted inside your Rails app."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    Dir["{app,config,db,lib}/**/*", "MIT-LICENSE", "Rakefile", "README.md"]
  end

  spec.add_dependency "rails", ">= 8.1.3"
end
