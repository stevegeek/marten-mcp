ENV["MARTEN_ENV"] = "test"

require "spec"
require "sqlite3"
require "../src/marten_mcp"
require "marten/spec"

require "./test_project/app"
require "./test_project/handlers"
require "./test_project/routes"

# Fixed test secret — reproducible failures beat per-run randomness. Must stay
# >= 32 bytes to satisfy Marten's secret-key length guidance.
SPEC_SECRET_KEY = "__insecure_spec_secret_DO_NOT_USE__"

Marten.configure :test do |config|
  config.secret_key = SPEC_SECRET_KEY
  config.log_level = ::Log::Severity::None

  config.installed_apps = [MartenMCPSpecApp]

  # The Host the Marten test client sends. Nothing in this suite depends on
  # the value: the test client sends no Origin header, so Origin.failure
  # returns before it reads allowed_hosts, and these bearer-only handlers
  # disable forgery protection, so nothing else consults it either. Emptying
  # the list leaves all specs green — verified, not assumed. It is set to a
  # realistic value so the suite resembles a deployment, and because the
  # Origin specs rewrite this setting and restore it to this one.
  config.allowed_hosts = ["127.0.0.1"]

  config.database do |db|
    db.backend = :sqlite
    db.name = ":memory:"
  end
end

Spec.after_each do
  Marten::MCP.settings.reset!
  SpecEndpointHandler.reset!
end
