module Marten::MCP
  module Protocol
    # A parsed JSON-RPC request, plus the one bit that decides how it is
    # served: whether the body carries its own protocol version. That is the
    # era switch. Both eras are served statelessly, so nothing else about the
    # request depends on which one it is.
    struct Envelope
      getter id : JSON::Any?
      getter method : String
      getter params : JSON::Any
      getter declared_version : String?
      getter client_name : String?
      getter client_version : String?

      EMPTY_PARAMS = JSON.parse("{}")

      def initialize(
        @id, @method, @params, @declared_version, @client_name, @client_version,
      )
      end

      # nil for unparseable JSON AND for JSON that is not a JSON-RPC request;
      # the caller distinguishes them by trying JSON.parse itself first.
      #
      # A caller can send ANY JSON shape here — an array, a bare scalar, an
      # object whose params is an array — and JSON::Any#[]?(String) raises a
      # bare Exception, not JSON::ParseException, when the receiver is not a
      # Hash. So every level is checked with as_h? before it is indexed by
      # name, rather than trusted: a wrong-typed field must fall out as
      # Invalid Request, never escape as an unhandled 500. Task 6's tool
      # lookups read #arguments and #tool_name through this same params, so
      # guarding it here once is what keeps those reads safe too.
      def self.parse(body : String) : Envelope?
        raw = JSON.parse(body).as_h?
        return nil if raw.nil?
        method = raw["method"]?.try(&.as_s?)
        return nil if method.nil?

        # params, if present at all, MUST be an object — a JSON-RPC request
        # with a positional (array) params is not a shape this server
        # understands, so it is Invalid Request rather than silently emptied.
        params_field = raw["params"]?
        return nil if params_field && params_field.as_h?.nil?
        params = params_field || EMPTY_PARAMS

        meta = params["_meta"]?.try(&.as_h?)
        client = meta.try { |m| m[META_CLIENT_INFO_KEY]? }.try(&.as_h?)
        Envelope.new(
          id: raw["id"]?,
          method: method,
          params: params,
          declared_version: meta.try { |m| m[META_VERSION_KEY]? }.try(&.as_s?),
          client_name: client.try { |c| c["name"]? }.try(&.as_s?),
          client_version: client.try { |c| c["version"]? }.try(&.as_s?),
        )
      rescue JSON::ParseException
        nil
      end

      def modern? : Bool
        !declared_version.nil?
      end

      # A JSON-RPC notification has no id at all. An explicit JSON null is
      # still an id-less message for our purposes.
      def notification? : Bool
        value = id
        value.nil? || value.raw.nil?
      end

      # Same `as_h?` discipline as `.parse` above, applied to the one nested
      # field that discipline missed: a caller can send `"arguments":5` (or
      # an array, string, null...) and `params["arguments"]?` on its own
      # would happily return that scalar. Args then indexes it with
      # `JSON::Any#[]?(String)`, which raises a bare Exception for a
      # non-Hash receiver (see the comment above) — past `tools_call`'s
      # `rescue error : Args::Invalid`, which does not catch it, and
      # out of the handler as an uncaught 500 with no audit row (found live
      # 2026-08-15). Falling back to EMPTY_PARAMS here means a malformed
      # `arguments` is instead just a call with no arguments — the tool's
      # own required-field checks take it from there, the same as if the
      # caller had omitted `arguments` entirely.
      def arguments : JSON::Any
        value = params["arguments"]?
        return EMPTY_PARAMS if value.nil? || value.as_h?.nil?
        value
      end

      def tool_name : String?
        params["name"]?.try(&.as_s?)
      end
    end
  end
end
