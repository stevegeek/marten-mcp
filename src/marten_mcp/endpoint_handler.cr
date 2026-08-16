module Marten::MCP
  # POST /mcp — the MCP endpoint. This class is the HTTP shell only: it
  # decides who is calling, hands the parsed envelope to the dispatcher, and
  # writes the audit row. No domain logic lives here.
  #
  # Subclass it and implement the hooks below. Every subclass MUST declare
  # `protect_from_forgery false` for itself — @@protect_from_forgery is
  # per-class storage in Crystal, so declaring it on this abstract parent
  # would not reach the subclass that is actually routed. Bearer-only is what
  # makes that exemption honest rather than a hole: this endpoint never reads
  # the session cookie, so a cross-site POST has no ambient authority to
  # borrow.
  abstract class EndpointHandler < Marten::Handler
    # REQUIRED. The shard cannot guess which proxy headers you trust.
    abstract def mcp_remote_ip : String?

    # REQUIRED.
    abstract def mcp_authenticate(
      request : Marten::HTTP::Request, ip : String?,
    ) : Marten::MCP::Caller | Marten::MCP::AuthFailure

    # Optional. Return true to reject with 429 BEFORE authentication.
    # Default false — no rate limiting. Implement it: this check is what stops
    # an unauthenticated caller flooding your audit table with denial rows.
    def mcp_ip_rate_limited?(ip : String?) : Bool
      false
    end

    # Optional. Called exactly once per request, except for an IP rate-limit
    # rejection. Default: no audit trail.
    def mcp_audit(record : Marten::MCP::CallRecord) : Nil
    end

    # Optional. The spec makes the Origin check a MUST, against DNS rebinding.
    # Override only if your deployment needs different host rules.
    def mcp_origin_failure : Marten::MCP::AuthFailure?
      Marten::MCP::Origin.failure(request)
    end

    # Optional. Builds the dispatcher that answers one request.
    #
    # This exists so a consumer can serve a JSON-RPC method this shard does not
    # implement — `resources/list`, say — by subclassing Dispatcher, handling
    # its own method names, and delegating everything else to `super`:
    #
    #     class MyDispatcher < Marten::MCP::Protocol::Dispatcher
    #       def call(envelope) : Outcome
    #         return resources_list(envelope) if envelope.method == "resources/list"
    #         super
    #       end
    #     end
    #
    #     def mcp_dispatcher(caller) : Marten::MCP::Protocol::Dispatcher
    #       MyDispatcher.new(caller)
    #     end
    #
    # Without this seam the only way to add a method is to reimplement `post`,
    # which means reimplementing the audit contract and the `recorded` guard
    # below — the two things most worth not rewriting.
    def mcp_dispatcher(caller : Marten::MCP::Caller) : Protocol::Dispatcher
      Protocol::Dispatcher.new(caller)
    end

    # Revision 2026-07-28 removed the GET stream and the DELETE session
    # teardown. A server that hosts neither answers 405 to both.
    def get
      empty(status: 405)
    end

    def delete
      empty(status: 405)
    end

    def post
      started = Time.instant
      ip = mcp_remote_ip
      caller : Caller? = nil
      envelope : Protocol::Envelope? = nil
      # Set true the instant the tail record succeeds, so the rescue below
      # can tell "already wrote a row, something raised on the way out
      # after that" from "never wrote one" — see the rescue clause.
      recorded = false

      begin
        if mcp_ip_rate_limited?(ip)
          # NOT audited — the one deliberate exception to "one row per call".
          # mcp_ip_rate_limited? runs before authentication precisely so an
          # unauthenticated caller cannot flood the audit trail; writing a row
          # here for every rejected request would defeat that by charging the
          # flood protection itself to the table it exists to protect. The
          # consumer's hook is the place to log that it fired — naming the IP,
          # since that log is now this event's only record — because the hook
          # already knows it is about to reject, and the line then lands under
          # the application's own log source.
          return rate_limited
        end

        if failure = mcp_origin_failure
          response = rpc_error(nil, -32001, failure.message, status: failure.status)
          return finish(nil, ip, nil, "denied", -32001, started, response,
            summary: failure.message, failure: failure)
        end

        resolved = mcp_authenticate(request, ip)
        if resolved.is_a?(AuthFailure)
          # Switched on status, not a single `429 ? : 401` shortcut — a future
          # AuthFailure carrying a status neither of those two branches names
          # (e.g. a 403) must reach the caller as itself, not get silently
          # rewritten to 401 by falling through to the default branch.
          response = case resolved.status
                     when 429
                       rate_limited
                     when 401
                       unauthorized(resolved.message)
                     else
                       rpc_error(nil, -32001, resolved.message, status: resolved.status)
                     end
          # The failure travels to the audit hook whole. A consumer subclass of
          # AuthFailure names the presented credential when the digest matched
          # a real row — the row that answers "is the token I revoked still
          # being used?" — and narrows back out of CallRecord#failure with
          # `as?`.
          return finish(nil, ip, nil, "denied", -32001, started, response,
            summary: resolved.message, failure: resolved)
        end
        caller = resolved.as(Caller)

        body = request.body
        begin
          JSON.parse(body)
        rescue JSON::ParseException
          response = rpc_error(nil, -32700, "Parse error", status: 400)
          return finish(caller, ip, nil, "error", -32700, started, response)
        end

        envelope = Protocol::Envelope.parse(body)
        if envelope.nil?
          response = rpc_error(nil, -32600, "Invalid Request", status: 400)
          return finish(caller, ip, nil, "error", -32600, started, response)
        end

        if message = Protocol::Headers.mismatch(request, envelope)
          response = rpc_error(envelope.id, -32020, "Header mismatch: #{message}", status: 400)
          return finish(caller, ip, envelope, "error", -32020, started, response)
        end

        outcome = mcp_dispatcher(caller).call(envelope)
        response = if outcome.status == 202
                     empty(status: 202)
                   else
                     json_raw(outcome.payload, status: outcome.status)
                   end
        # Spec §6's insufficient-scope challenge. Set here rather than in the
        # dispatcher because the dispatcher builds no HTTP response.
        if challenge = outcome.challenge
          response.headers["WWW-Authenticate"] = challenge
        end

        mcp_audit(CallRecord.new(
          caller: caller, ip: ip,
          rpc_method: envelope.method,
          # A 202 (every notification, not just tools/call ones) never runs
          # the dispatcher's method case, so Outcome#tool_name is always nil
          # for it — fall back to what the envelope itself named, but ONLY
          # for tools/call: params.name is a tool-call-shaped field, and a
          # method that never named a tool (e.g. resources/list carrying an
          # unrelated "name" param) must not have one attributed to it.
          tool_name: outcome.tool_name || (envelope.method == "tools/call" ? envelope.tool_name : nil),
          # Distinct from "ok": a notification is accepted, not executed. A
          # notified tools/call carries a tool_name and arguments but never
          # ran — "ok" would read as a successful call that never happened.
          outcome: outcome.status == 202 ? "accepted" : outcome.outcome,
          error_code: outcome.error_code,
          arguments: envelope.method == "tools/call" ? envelope.arguments : nil,
          summary: outcome.summary,
          duration_us: elapsed_us(started),
          client_name: envelope.client_name, client_version: envelope.client_version,
          protocol_version: envelope.declared_version,
        ))
        recorded = true
        response
      rescue error
        # Catch-all beneath every named failure above (an AuthFailure, a
        # parse error, a header mismatch — each already produces its own
        # row). This is for what those did not anticipate: a tool raising
        # past Args::Invalid (Envelope#arguments' as_h? guard closes the one
        # shape found live; a next one may not be), a rate limiter's backing
        # store unreachable, a DB error inside mcp_authenticate, a dangling
        # association the audit hook dereferences. The property this class
        # exists to guarantee — one row per call, no silent gap — has to hold
        # for exceptions this code did not name, not only the ones it did.
        #
        # `recorded` guards the one case where that same guarantee would
        # tip over into a DOUBLE row: something raising after the tail
        # record above already succeeded (a header write, a metrics call —
        # nothing does today, but nothing stops one being added). Today the
        # only statement between the record and returning is a bare local
        # read that cannot raise, so this is currently unreachable — the
        # flag makes that a guarantee instead of an accident of statement
        # order.
        #
        # `::Log`, not `Log`: inside Marten::MCP the bare constant resolves to
        # Marten::Log, an instance whose children are all sourced under
        # "marten." — which would move this line out from under the source the
        # consumer configured.
        ::Log.for("#{Marten::MCP.settings.log_source}.endpoint")
          .error(exception: error) { "MCP request failed unexpectedly" }
        response = rpc_error(envelope.try(&.id), -32603, "Internal error", status: 500)
        recorded ? response : finish(caller, ip, envelope, "error", -32603, started, response)
      end
    end

    # The single audit-and-return path for every early exit (Origin, auth
    # failure, the parse/shape/header errors that precede the dispatcher,
    # and the catch-all rescue) — the IP rate limit is the one exception,
    # see above. One call site here — and one at the tail of `post` for the
    # dispatched path — means every other exit produces exactly one row.
    private def finish(
      caller : Caller?, ip : String?, envelope : Protocol::Envelope?,
      outcome : String, error_code : Int32?, started : Time::Instant,
      response : Marten::HTTP::Response, summary : String? = nil,
      failure : AuthFailure? = nil,
    ) : Marten::HTTP::Response
      mcp_audit(CallRecord.new(
        caller: caller, failure: failure, ip: ip,
        rpc_method: envelope.try(&.method), tool_name: envelope.try(&.tool_name),
        outcome: outcome, error_code: error_code,
        arguments: nil, summary: summary,
        duration_us: elapsed_us(started),
        client_name: envelope.try(&.client_name),
        client_version: envelope.try(&.client_version),
        protocol_version: envelope.try(&.declared_version),
      ))
      response
    end

    private def elapsed_us(started : Time::Instant) : Int32
      # Microseconds, not milliseconds: nearly every call here completes in
      # well under a millisecond, and a millisecond column — even rounded —
      # read as 0 for nearly every row (measured live, fix round 2), which
      # is worse than no column at all since 0 looks like data. Int32 tops
      # out around 35 minutes of microseconds, far past any request this
      # endpoint serves.
      (Time.instant - started).total_microseconds.round.to_i32
    end

    private def rate_limited : Marten::HTTP::Response
      rpc_error(nil, -32001, "Rate limit exceeded", status: 429)
    end

    # 401 with a BARE Bearer challenge. Deliberately no resource_metadata
    # parameter: that parameter is what makes an MCP client begin OAuth
    # discovery, and a server using this shard hosts no authorization server.
    private def unauthorized(message : String) : Marten::HTTP::Response
      response = rpc_error(nil, -32001, message, status: 401)
      response.headers["WWW-Authenticate"] = "Bearer"
      response
    end

    private def json(payload, status : Int32 = 200) : Marten::HTTP::Response
      response = respond(content: payload.to_json, content_type: "application/json", status: status)
      response.headers["Cache-Control"] = "private, no-store"
      response
    end

    private def json_raw(payload : String, status : Int32 = 200) : Marten::HTTP::Response
      response = respond(content: payload, content_type: "application/json", status: status)
      response.headers["Cache-Control"] = "private, no-store"
      response
    end

    # The 405s and the 202-on-notification share this: an empty body with no
    # payload to carry the header on its way out through `json`/`json_raw`.
    # A consuming application may stamp Cache-Control from a cache middleware
    # of its own — the extracted app does, and no rule there matches /mcp, so
    # every response falls through to that middleware's private-no-store
    # default and gets the header stamped on unconditionally. Setting it here
    # too is belt-and-braces: correct in isolation, for a consumer that runs
    # no such middleware, and a second layer if the cache rules or the
    # middleware order ever change.
    private def empty(status : Int32) : Marten::HTTP::Response
      response = respond(content: "", content_type: "application/json", status: status)
      response.headers["Cache-Control"] = "private, no-store"
      response
    end

    private def rpc_error(
      id : JSON::Any?, code : Int32, message : String, status : Int32,
    ) : Marten::HTTP::Response
      json({jsonrpc: "2.0", id: id, error: {code: code, message: message}}, status: status)
    end
  end
end
