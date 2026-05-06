ENV["MARTEN_ENV"] = "test"

require "spec"
require "sqlite3"
require "../src/marten_encoded_id"
require "marten/spec"

# Test app + models. Loaded before Marten.configure so the App class
# constants exist when installed_apps is set up.
require "./test_project/app"
require "./test_project/models/**"

# Configure global MartenEncodedId defaults for the spec that exercises
# the no-explicit-coder form.
MartenEncodedId.configure do |c|
  c.salt = "spec-global-salt"
  c.min_length = 6
end

Marten.configure :test do |config|
  config.secret_key = "__insecure_spec_secret_#{Random::Secure.random_bytes(16).hexstring}__"
  config.log_level = ::Log::Severity::None

  config.installed_apps = [MartenEncodedIdSpecApp]

  config.database do |db|
    db.backend = :sqlite
    db.name = ":memory:"
  end
end
