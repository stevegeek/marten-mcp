# A minimal consumer, standing in for a real application: the hooks are backed
# by class-level fakes a spec can set and inspect.
class SpecCaller
  include Marten::MCP::Caller

  def initialize(@capabilities : Set(Symbol))
  end

  def can?(capability : Symbol) : Bool
    @capabilities.includes?(capability)
  end
end

class SpecEndpointHandler < Marten::MCP::EndpointHandler
  # REQUIRED in every subclass: @@protect_from_forgery is per-class storage in
  # Crystal, so the abstract parent cannot set it. Bearer-only means this
  # endpoint never reads the session cookie.
  protect_from_forgery false

  class_property audited = [] of Marten::MCP::CallRecord
  class_property rate_limited = false
  class_property authenticate : Proc(Marten::MCP::Caller | Marten::MCP::AuthFailure) = -> { SpecCaller.new(Set{:read}).as(Marten::MCP::Caller | Marten::MCP::AuthFailure) }

  def self.reset! : Nil
    @@audited = [] of Marten::MCP::CallRecord
    @@rate_limited = false
    @@authenticate = -> { SpecCaller.new(Set{:read}).as(Marten::MCP::Caller | Marten::MCP::AuthFailure) }
  end

  def mcp_remote_ip : String?
    request.headers["X-Forwarded-For"]?
  end

  def mcp_ip_rate_limited?(ip : String?) : Bool
    self.class.rate_limited
  end

  def mcp_authenticate(request, ip) : Marten::MCP::Caller | Marten::MCP::AuthFailure
    self.class.authenticate.call
  end

  def mcp_audit(record : Marten::MCP::CallRecord) : Nil
    self.class.audited << record
  end
end

# A second handler implementing only the two REQUIRED hooks, proving the
# optional ones' defaults leave a working endpoint.
class SpecBareHandler < Marten::MCP::EndpointHandler
  protect_from_forgery false

  def mcp_remote_ip : String?
    nil
  end

  def mcp_authenticate(request, ip) : Marten::MCP::Caller | Marten::MCP::AuthFailure
    SpecCaller.new(Set{:read}).as(Marten::MCP::Caller | Marten::MCP::AuthFailure)
  end
end

# A third handler proving the mcp_dispatcher seam: a consumer serving a
# JSON-RPC method this shard does not implement, without reimplementing `post`
# and therefore without reimplementing the audit contract.
class SpecExtendedDispatcher < Marten::MCP::Protocol::Dispatcher
  def call(envelope : Marten::MCP::Protocol::Envelope) : Outcome
    return shop_ping(envelope) if envelope.method == "shop/ping"
    super
  end

  private def shop_ping(envelope : Marten::MCP::Protocol::Envelope) : Outcome
    Outcome.new(
      %({"jsonrpc":"2.0","id":#{(envelope.id || JSON::Any.new(nil)).to_json},"result":{"shop":"ok"}}),
      200, "ok")
  end
end

class SpecExtendedHandler < Marten::MCP::EndpointHandler
  protect_from_forgery false

  class_property audited = [] of Marten::MCP::CallRecord

  def self.reset! : Nil
    @@audited = [] of Marten::MCP::CallRecord
  end

  def mcp_remote_ip : String?
    nil
  end

  def mcp_authenticate(request, ip) : Marten::MCP::Caller | Marten::MCP::AuthFailure
    SpecCaller.new(Set{:read}).as(Marten::MCP::Caller | Marten::MCP::AuthFailure)
  end

  def mcp_dispatcher(caller : Marten::MCP::Caller) : Marten::MCP::Protocol::Dispatcher
    SpecExtendedDispatcher.new(caller)
  end

  def mcp_audit(record : Marten::MCP::CallRecord) : Nil
    self.class.audited << record
  end
end
