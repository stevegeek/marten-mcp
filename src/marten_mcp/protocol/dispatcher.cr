module Marten::MCP
  module Protocol
    # Envelope + Caller -> a serialized JSON-RPC payload and the facts the
    # audit row needs. Knows nothing about HTTP beyond the status it asks for.
    class Dispatcher
      struct Outcome
        getter payload : String
        getter status : Int32
        getter outcome : String # ok | denied | error
        getter error_code : Int32?
        getter tool_name : String?
        getter summary : String?
        # A WWW-Authenticate value for the HTTP shell to stamp on the
        # response. Only the insufficient-scope 403 sets it; the 401
        # challenges never reach the dispatcher, since authentication fails
        # before it runs.
        getter challenge : String?

        def initialize(
          @payload, @status, @outcome,
          @error_code = nil, @tool_name = nil, @summary = nil,
          @challenge = nil,
        )
        end
      end

      def initialize(@caller : Caller)
      end

      def call(envelope : Envelope) : Outcome
        if (version = envelope.declared_version) && !Protocol.supported?(version)
          return unsupported_version(envelope, version)
        end

        # JSON-RPC forbids replying to a notification and the transport
        # names the answer: 202, no body. Only notifications/initialized is
        # cased below, so without this a legacy client's
        # notifications/cancelled (or notifications/roots/list_changed, sent
        # by any client declaring the roots capability) comes back a 404.
        # AFTER the version check on purpose: the transport allows an HTTP
        # error for a notification the server cannot accept, so an
        # unsupported declared version still 400s.
        return accepted if envelope.notification?

        case envelope.method
        when "initialize"                then initialize_result(envelope)
        when "notifications/initialized" then accepted
        when "server/discover"           then discover(envelope)
        when "ping"                      then result(envelope, "{}")
        when "tools/list"                then tools_list(envelope)
        when "tools/call"                then tools_call(envelope)
        else                                  method_not_found(envelope)
        end
      end

      # --- methods ---------------------------------------------------------

      private def initialize_result(envelope : Envelope) : Outcome
        negotiated = Protocol.negotiate(envelope.params["protocolVersion"]?.try(&.as_s?))
        settings = Marten::MCP.settings
        body = String.build do |io|
          io << %({"protocolVersion":) << negotiated.to_json
          io << %(,"capabilities":{"tools":{}})
          io << %(,"serverInfo":{"name":) << settings.server_name.to_json
          io << %(,"version":) << settings.server_version.to_json << '}'
          if instructions = settings.instructions
            io << %(,"instructions":) << instructions.to_json
          end
          io << '}'
        end
        # No resultType here on purpose: initialize is legacy-only, and a
        # legacy client validating against its own schema must not see a field
        # that revision never defined.
        Outcome.new(envelope_json(envelope.id, body), 200, "ok")
      end

      private def discover(envelope : Envelope) : Outcome
        settings = Marten::MCP.settings
        body = String.build do |io|
          io << %({"resultType":"complete")
          # 1 hour: this body is identical for every caller — supported
          # versions, capabilities, and instructions are all constants — so
          # a long TTL costs nothing. "private" would not be strictly
          # required by the content, but we choose it anyway for
          # consistency with the transport, which stamps
          # Cache-Control: private, no-store on every response from this
          # endpoint; a public cache directive on an authenticated
          # endpoint ages badly.
          io << %(,"ttlMs":3600000)
          io << %(,"cacheScope":"private")
          io << %(,"supportedVersions":) << Protocol::SUPPORTED.to_json
          io << %(,"capabilities":{"tools":{}})
          if instructions = settings.instructions
            io << %(,"instructions":) << instructions.to_json
          end
          io << %(,"_meta":{) << Protocol::META_SERVER_INFO_KEY.to_json
          io << %(:{"name":) << settings.server_name.to_json
          io << %(,"version":) << settings.server_version.to_json << %(}})
          io << '}'
        end
        Outcome.new(envelope_json(envelope.id, body), 200, "ok")
      end

      # cacheScope "private" is load-bearing, not a style choice:
      # Registry.visible_for filters the tool list against the caller's
      # effective capabilities, so a read-only token never learns a delete
      # tool exists. Declaring the list publicly cacheable would invite an
      # intermediary to serve one token's tool list to another, defeating
      # the registry's whole purpose. The 5-minute ttlMs is only a courtesy
      # cap: tools/call re-checks the capability independently, so a stale
      # cached list can never grant access by itself — the list is a
      # courtesy, the call check is the gate.
      TOOLS_LIST_CACHE = %("ttlMs":300000,"cacheScope":"private")

      private def tools_list(envelope : Envelope) : Outcome
        definitions = Registry.visible_for(@caller).map(&.definition_json)
        result(envelope, %({"tools":[#{definitions.join(",")}]}), TOOLS_LIST_CACHE)
      end

      # Spec §6: an authenticated caller that lacks the capability for a tool
      # gets 403 with this challenge. Deliberately no resource_metadata
      # parameter, for the same reason the 401 challenge omits it — that
      # parameter is what makes an MCP client begin OAuth discovery, and a
      # server using this shard hosts no authorization server.
      INSUFFICIENT_SCOPE_CHALLENGE = %(Bearer error="insufficient_scope")

      private def tools_call(envelope : Envelope) : Outcome
        name = envelope.tool_name
        if name.nil?
          return Outcome.new(
            error_json(envelope.id, -32602, "Missing tool name"), 400, "error",
            error_code: -32602)
        end

        tool = Registry.find(name)
        # Unknown and forbidden answer differently on purpose: a caller that
        # holds SOME capability may legitimately mistype a tool name, and
        # -32602 tells them so. A tool they may not use answers 403 with the
        # scope challenge instead, and never confirms it exists.
        if tool.nil?
          return Outcome.new(
            error_json(envelope.id, -32602, "Unknown tool: #{Echo.cap(name)}"), 400, "error",
            error_code: -32602, tool_name: name)
        end

        unless @caller.can?(tool.capability)
          return Outcome.new(
            error_json(envelope.id, -32001, "Insufficient scope for #{Echo.cap(name)}"), 403,
            "denied", error_code: -32001, tool_name: name,
            challenge: INSUFFICIENT_SCOPE_CHALLENGE)
        end

        begin
          tool_result = tool.call(@caller, Args.new(envelope.arguments))
        rescue error : Args::Invalid
          return Outcome.new(
            error_json(envelope.id, -32602, "Invalid params: #{error.message}"), 400,
            "error", error_code: -32602, tool_name: name)
        end

        body = String.build do |io|
          io << %({"content":[{"type":"text","text":) << tool_result.text.to_json << "}]"
          if structured = tool_result.structured
            io << %(,"structuredContent":) << structured
          end
          io << %(,"isError":) << tool_result.is_error << "}"
        end

        # Reuses result(...) only for its payload, so the modern/legacy
        # resultType rule stays in one place instead of being duplicated here.
        Outcome.new(
          result(envelope, body).payload, 200,
          tool_result.is_error ? "error" : "ok",
          tool_name: name, summary: tool_result.summary)
      end

      # --- shapes ----------------------------------------------------------

      # resultType — and whatever modern_fields a caller passes — only for
      # modern callers: a legacy client validating against its own schema
      # must never see a field its revision does not define. This is the
      # one place that distinction lives; callers that need extra
      # modern-only fields (tools/list's ttlMs/cacheScope) pass them in
      # here rather than branching on envelope.modern? themselves.
      private def result(envelope : Envelope, body_json : String, modern_fields : String? = nil) : Outcome
        body = if envelope.modern?
                 inner = body_json.lchop('{').rchop('}').strip
                 fields = String.build do |io|
                   io << %("resultType":"complete")
                   io << ',' << modern_fields if modern_fields
                   io << ',' << inner unless inner.empty?
                 end
                 "{#{fields}}"
               else
                 body_json
               end
        Outcome.new(envelope_json(envelope.id, body), 200, "ok")
      end

      private def accepted : Outcome
        Outcome.new("", 202, "ok")
      end

      private def method_not_found(envelope : Envelope) : Outcome
        Outcome.new(
          error_json(envelope.id, -32601, "Method not found: #{Echo.cap(envelope.method)}"),
          404, "error", error_code: -32601)
      end

      private def unsupported_version(envelope : Envelope, requested : String) : Outcome
        payload = {
          jsonrpc: "2.0",
          id:      envelope.id,
          error:   {
            code:    -32022,
            message: "Unsupported protocol version",
            data:    {supported: Protocol::SUPPORTED, requested: requested},
          },
        }.to_json
        Outcome.new(payload, 400, "error", error_code: -32022)
      end

      private def envelope_json(id : JSON::Any?, body_json : String) : String
        %({"jsonrpc":"2.0","id":#{(id || JSON::Any.new(nil)).to_json},"result":#{body_json}})
      end

      private def error_json(id : JSON::Any?, code : Int32, message : String) : String
        {jsonrpc: "2.0", id: id, error: {code: code, message: message}}.to_json
      end
    end
  end
end
