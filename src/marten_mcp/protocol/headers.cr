require "base64"

module Marten::MCP
  module Protocol
    # Streamable HTTP mirrors `method` and `params.name` into HTTP headers so
    # intermediaries can route without parsing the body. A server that reads
    # the body MUST reject a disagreement: otherwise a load balancer and the
    # server could act on two different truths from one request.
    #
    # Modern requests only. A legacy client never sends these headers.
    module Headers
      extend self

      SENTINEL_PREFIX = "=?base64?"
      SENTINEL_SUFFIX = "?="

      def mismatch(request : Marten::HTTP::Request, envelope : Envelope) : String?
        return nil unless envelope.modern?

        version = request.headers["MCP-Protocol-Version"]?
        return "MCP-Protocol-Version header is missing" if version.nil?
        if version != envelope.declared_version
          return "MCP-Protocol-Version header does not match the body"
        end

        method = request.headers["Mcp-Method"]?
        return "Mcp-Method header is missing" if method.nil?
        return "Mcp-Method header does not match the body" if method != envelope.method

        expected = envelope.params["name"]?.try(&.as_s?)
        return nil if expected.nil?
        name = request.headers["Mcp-Name"]?
        return "Mcp-Name header is missing" if name.nil?
        return "Mcp-Name header does not match the body" if decode(name) != expected

        nil
      end

      # Values that cannot travel as plain ASCII arrive wrapped in a
      # case-sensitive sentinel. A body that is not valid base64 is returned
      # untouched, so it fails the comparison rather than raising.
      def decode(value : String) : String
        return value unless value.starts_with?(SENTINEL_PREFIX) && value.ends_with?(SENTINEL_SUFFIX)
        inner = value[SENTINEL_PREFIX.size..-(SENTINEL_SUFFIX.size + 1)]
        String.new(Base64.decode(inner))
      rescue Base64::Error
        value
      end
    end
  end
end
