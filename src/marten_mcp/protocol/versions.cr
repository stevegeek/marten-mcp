module Marten::MCP
  module Protocol
    # Revision 2026-07-28 dropped the initialize handshake and sessions; we
    # still answer the two revisions before it, because the spec's own
    # compatibility matrix says a legacy client meeting a modern-only server
    # simply fails, with no fall-forward.
    MODERN         = "2026-07-28"
    SUPPORTED      = [MODERN, "2025-11-25", "2025-06-18"]
    LEGACY_DEFAULT = "2025-06-18"

    META_VERSION_KEY     = "io.modelcontextprotocol/protocolVersion"
    META_CLIENT_INFO_KEY = "io.modelcontextprotocol/clientInfo"
    META_SERVER_INFO_KEY = "io.modelcontextprotocol/serverInfo"

    def self.supported?(version : String) : Bool
      SUPPORTED.includes?(version)
    end

    # A legacy client proposes a version in initialize; we answer with the
    # same one when we speak it, otherwise with LEGACY_DEFAULT — the OLDEST
    # revision we speak, so a client whose proposal we do not recognise is
    # answered with the floor rather than something it may not implement.
    def self.negotiate(requested : String?) : String
      return LEGACY_DEFAULT if requested.nil?
      supported?(requested) ? requested : LEGACY_DEFAULT
    end
  end
end
