require "./spec_helper"

# The Host every request below carries. Origin.failure never reads it, but a
# request with no Host at all is not a shape this check will ever see.
private SPEC_HOST = "127.0.0.1"

private def request_with(origin : String? = nil) : Marten::HTTP::Request
  headers = ::HTTP::Headers{"Host" => SPEC_HOST}
  headers["Origin"] = origin if origin
  Marten::HTTP::Request.new(
    ::HTTP::Request.new(method: "POST", resource: "/mcp", headers: headers)
  )
end

describe Marten::MCP::Origin do
  # allowed_hosts is a global setting, and spec_helper pins it to the one Host
  # the test client sends. Every example below rewrites it; restore it here so
  # the integration specs that follow still reach their handler.
  after_each do
    Marten.settings.allowed_hosts = [SPEC_HOST]
    Marten.settings.debug = false
  end

  describe "#failure" do
    it "returns nil when the Origin header is absent — a CLI client sends none" do
      Marten::MCP::Origin.failure(request_with).should be_nil
    end

    it "returns nil when the Origin header is empty" do
      Marten::MCP::Origin.failure(request_with("")).should be_nil
    end

    it "returns nil for a host named in allowed_hosts" do
      Marten.settings.allowed_hosts = ["example.com"]
      Marten::MCP::Origin.failure(request_with("https://example.com")).should be_nil
    end

    it "returns a 403 failure for a foreign host" do
      Marten.settings.allowed_hosts = ["example.com"]
      failure = Marten::MCP::Origin.failure(request_with("https://evil.example.net"))
      failure.should_not be_nil
      failure.not_nil!.status.should eq 403
      failure.not_nil!.message.should eq "Origin not allowed"
    end

    # host is nil here, so this never reaches allowed_origin_host? — it fails
    # closed on the main path rather than in the rescue.
    it "returns a 403 failure for a value that parses to no host at all" do
      Marten.settings.allowed_hosts = ["example.com"]
      Marten::MCP::Origin.failure(request_with("not-a-url")).try(&.status).should eq 403
    end

    # The reason the rescue catches Exception and not URI::Error: this value
    # raises OverflowError out of URI.parse.
    it "returns a 403 failure for an out-of-range port" do
      Marten.settings.allowed_hosts = ["example.com"]
      Marten::MCP::Origin.failure(request_with("http://x:99999999999999")).try(&.status).should eq 403
    end

    it "matches a leading-dot pattern against both the bare domain and a subdomain" do
      Marten.settings.allowed_hosts = [".example.com"]
      Marten::MCP::Origin.failure(request_with("https://example.com")).should be_nil
      Marten::MCP::Origin.failure(request_with("https://api.example.com")).should be_nil
    end

    it "does not let a leading-dot pattern match a lookalike domain" do
      Marten.settings.allowed_hosts = [".example.com"]
      Marten::MCP::Origin.failure(request_with("https://notexample.com")).try(&.status).should eq 403
    end

    it "matches case-insensitively, in the pattern and in the Origin" do
      Marten.settings.allowed_hosts = ["EXAMPLE.com"]
      Marten::MCP::Origin.failure(request_with("https://Example.COM")).should be_nil
    end

    it "admits everything under a wildcard pattern" do
      Marten.settings.allowed_hosts = ["*"]
      Marten::MCP::Origin.failure(request_with("https://evil.example.net")).should be_nil
    end

    # URI.parse("http://").host is "", not nil, so it reaches the pattern loop.
    # An empty pattern that was not skipped would compare equal to it and admit
    # the request.
    it "does not let an empty pattern admit `Origin: http://`" do
      Marten.settings.allowed_hosts = ["", "example.com"]
      Marten::MCP::Origin.failure(request_with("http://")).try(&.status).should eq 403
    end

    # `pattern[0]` raises IndexError on an empty string, so an unskipped empty
    # pattern does not merely admit the wrong host — it takes the whole list
    # down with it, and every Origin then falls closed into the rescue. This is
    # the assertion that actually pins the skip: the case above stays 403
    # either way.
    it "skips an empty pattern instead of failing the rest of the list on it" do
      Marten.settings.allowed_hosts = ["", "example.com"]
      Marten::MCP::Origin.failure(request_with("https://example.com")).should be_nil
    end

    it "falls back to the debug host list when allowed_hosts is empty and debug is on" do
      Marten.settings.allowed_hosts = [] of String
      Marten.settings.debug = true
      Marten::MCP::Origin.failure(request_with("http://127.0.0.1:8000")).should be_nil
      Marten::MCP::Origin.failure(request_with("http://app.localhost")).should be_nil
      Marten::MCP::Origin.failure(request_with("https://evil.example.net")).try(&.status).should eq 403
    end

    it "does not fall back to the debug host list when debug is off" do
      Marten.settings.allowed_hosts = [] of String
      Marten.settings.debug = false
      Marten::MCP::Origin.failure(request_with("http://127.0.0.1:8000")).try(&.status).should eq 403
    end
  end
end
