require "uri"

module Marten::MCP
  # The Origin check the MCP spec makes a MUST, against DNS rebinding.
  module Origin
    extend self

    # Marten's own fallback host list when `allowed_hosts` is empty and
    # `debug` is true (a development configuration commonly leaves
    # allowed_hosts unset). Mirrors the private
    # Marten::HTTP::Request::DEFAULT_DEBUG_ALLOWED_HOSTS
    # (lib/marten/src/marten/http/request.cr). Trusting this same list for
    # Origin is safe for the same reason trusting it for Host is safe:
    # Marten's own Host validation (Request#extract_and_validate_host_and_port)
    # already rejects any request whose Host header falls outside it, so a
    # DNS-rebinding attack forging this Origin still needs a Host Marten
    # accepts — and Marten already limits that to this same list.
    DEBUG_ALLOWED_HOSTS = [".localhost", "127.0.0.1", "[::1]"]

    # nil when the Origin header is absent (a CLI client sends none) or when
    # it names one of our own hosts; an AuthFailure otherwise.
    def failure(request : Marten::HTTP::Request) : AuthFailure?
      origin = request.headers["Origin"]?
      return nil if origin.nil? || origin.empty?
      host = URI.parse(origin).host
      return nil if host && allowed_origin_host?(host)
      AuthFailure.new(403, "Origin not allowed")
    rescue Exception
      # origin is attacker-controlled. URI.parse does not only raise
      # URI::Error on a malformed value — an out-of-range port (e.g.
      # "http://x:99999999999999") raises OverflowError instead — and every
      # parse outcome that is not a recognised host must fail closed, so
      # catch broadly rather than name each exception class URI.parse might
      # throw.
      AuthFailure.new(403, "Origin not allowed")
    end

    # Mirrors Marten::HTTP::Request#allowed_host? (private there,
    # lib/marten/src/marten/http/request.cr): wildcard "*", a leading-dot
    # pattern matches both the bare domain and its subdomains, matching is
    # case-insensitive, and an empty pattern is skipped — URI.parse("http://").host
    # returns "", not nil, so an unskipped empty pattern would otherwise
    # admit `Origin: http://`. A config value like
    # MARTEN_ALLOWED_HOSTS=.example.com must accept the same Origins it
    # accepts Hosts, or a valid config becomes a 403 trap that is painful to
    # diagnose.
    private def allowed_origin_host?(host : String) : Bool
      host = host.downcase
      patterns = Marten.settings.allowed_hosts
      patterns = DEBUG_ALLOWED_HOSTS if Marten.settings.debug && patterns.empty?
      patterns.any? do |pattern|
        next false if pattern.empty?
        pattern = pattern.downcase
        next true if pattern == "*"
        next true if pattern[0] == '.' && (host.ends_with?(pattern) || host == pattern[1..])
        pattern == host
      end
    end
  end
end
