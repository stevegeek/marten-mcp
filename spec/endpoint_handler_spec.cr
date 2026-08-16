require "./spec_helper"

Spec.before_each { Marten::MCP::Registry.all.clear }

private def mcp_path : String
  Marten.routes.reverse("spec_mcp")
end

private def bare_path : String
  Marten.routes.reverse("spec_bare")
end

private def post_mcp(
  body : String,
  headers : Hash(String, String) = {} of String => String,
  path : String = mcp_path,
) : Marten::HTTP::Response
  Marten::Spec.client.post(path, data: body, content_type: "application/json", headers: headers)
end

private def audited : Array(Marten::MCP::CallRecord)
  SpecEndpointHandler.audited
end

# Every assertion about a record goes through here, so "exactly one row" is
# re-checked on every single case rather than only the two that name it.
private def only_record : Marten::MCP::CallRecord
  audited.size.should eq 1
  audited.first
end

private def error_code_of(response : Marten::HTTP::Response) : Int64
  JSON.parse(response.content)["error"]["code"].as_i64
end

# The `as` inside the proc is load-bearing: Crystal binds a parameter to the
# CONCRETE type it was called with, so `->{ result }` on its own would build a
# Proc(AuthFailure), which the class property cannot hold.
private def authenticate_as(result : Marten::MCP::Caller | Marten::MCP::AuthFailure) : Nil
  SpecEndpointHandler.authenticate = -> { result.as(Marten::MCP::Caller | Marten::MCP::AuthFailure) }
end

# Carries a credential the way a real consumer's failure does, so a spec can
# prove the subclass survives the trip to mcp_audit.
private class SpecTokenFailure < Marten::MCP::AuthFailure
  getter token : String

  def initialize(@token : String, status : Int32, message : String)
    super(status, message)
  end
end

private class SpecReadTool < Marten::MCP::Tool
  def name : String
    "spec_read"
  end

  def title : String
    "Spec Read"
  end

  def description : String
    "Reads something."
  end

  def capability : Symbol
    :read
  end

  def input_schema : String
    %({"type":"object","properties":{}})
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(text: "read")
  end
end

# The default SpecCaller holds :read only, so this one is always out of reach.
private class SpecWriteTool < SpecReadTool
  def name : String
    "spec_write"
  end

  def capability : Symbol
    :write
  end
end

# Raises something no named branch of the lifecycle anticipates — the case the
# catch-all rescue exists for.
private class SpecBoomTool < SpecReadTool
  def name : String
    "spec_boom"
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    raise "tool exploded"
  end
end

private def call_tool_body(name : String, arguments : String = "{}", id : String? = "1") : String
  id_member = id.nil? ? "" : %("id":#{id},)
  %({"jsonrpc":"2.0",#{id_member}"method":"tools/call","params":{"name":#{name.to_json},"arguments":#{arguments}}})
end

private PING = %({"jsonrpc":"2.0","id":1,"method":"ping"})

describe Marten::MCP::EndpointHandler do
  describe "the methods it does not host" do
    it "405s a GET — this revision hosts no SSE stream" do
      Marten::Spec.client.get(mcp_path).status.should eq 405
    end

    it "405s a DELETE — there is no session to terminate" do
      Marten::Spec.client.delete(mcp_path).status.should eq 405
    end
  end

  describe "the dispatched path" do
    it "serves a ping and writes exactly one audit record" do
      response = post_mcp(PING, headers: {"X-Forwarded-For" => "203.0.113.7"})
      response.status.should eq 200
      JSON.parse(response.content)["result"].should eq JSON.parse("{}")

      record = only_record
      record.outcome.should eq "ok"
      record.error_code.should be_nil
      record.caller.should_not be_nil
      record.failure.should be_nil
      record.rpc_method.should eq "ping"
      record.ip.should eq "203.0.113.7"
      record.duration_us.should be > 0
    end

    it "records the client identity the envelope declared" do
      body = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{) +
             %("io.modelcontextprotocol/protocolVersion":"2026-07-28",) +
             %("io.modelcontextprotocol/clientInfo":{"name":"spec-cli","version":"9.9"}}}})
      post_mcp(body, headers: {
        "MCP-Protocol-Version" => "2026-07-28",
        "Mcp-Method"           => "ping",
      }).status.should eq 200

      record = only_record
      record.protocol_version.should eq "2026-07-28"
      record.client_name.should eq "spec-cli"
      record.client_version.should eq "9.9"
    end

    it "answers 202 with an empty body for a notification, and audits it as accepted" do
      response = post_mcp(%({"jsonrpc":"2.0","method":"notifications/initialized"}))
      response.status.should eq 202
      response.content.should eq ""
      only_record.outcome.should eq "accepted"
    end
  end

  describe "the IP rate limit" do
    # The ONE deliberate exception to one-row-per-call: this check runs before
    # authentication so an unauthenticated caller cannot flood the audit trail,
    # and a row here would charge the flood protection to the thing it protects.
    it "429s and writes ZERO audit records" do
      SpecEndpointHandler.rate_limited = true
      response = post_mcp(PING)
      response.status.should eq 429
      error_code_of(response).should eq -32001
      audited.size.should eq 0
    end
  end

  describe "the Origin check" do
    it "403s a foreign Origin and audits the denial" do
      response = post_mcp(PING, headers: {"Origin" => "https://evil.example.net"})
      response.status.should eq 403
      error_code_of(response).should eq -32001

      record = only_record
      record.outcome.should eq "denied"
      record.error_code.should eq -32001
      record.caller.should be_nil
      record.failure.try(&.status).should eq 403
      record.summary.should eq "Origin not allowed"
    end

    it "lets an Origin naming one of our own hosts through" do
      post_mcp(PING, headers: {"Origin" => "https://127.0.0.1"}).status.should eq 200
    end
  end

  describe "an authentication failure" do
    it "401s with a BARE Bearer challenge, and audits denied / -32001" do
      authenticate_as(Marten::MCP::AuthFailure.new(401, "Invalid token"))
      response = post_mcp(PING)
      response.status.should eq 401
      response.headers["WWW-Authenticate"].should eq "Bearer"
      response.headers["WWW-Authenticate"].to_s.should_not contain "resource_metadata"

      record = only_record
      record.outcome.should eq "denied"
      record.error_code.should eq -32001
      record.summary.should eq "Invalid token"
      record.caller.should be_nil
    end

    it "429s a rate-limited caller" do
      authenticate_as(Marten::MCP::AuthFailure.new(429, "Rate limit exceeded"))
      response = post_mcp(PING)
      response.status.should eq 429
      only_record.outcome.should eq "denied"
    end

    # The reason the status mapping is a `case` and not a `429 ? : 401`
    # shortcut: a status neither branch names must reach the caller as itself.
    it "passes a 403 through as a 403 rather than rewriting it to 401" do
      authenticate_as(Marten::MCP::AuthFailure.new(403, "Account suspended"))
      response = post_mcp(PING)
      response.status.should eq 403
      response.headers["WWW-Authenticate"]?.should be_nil
      JSON.parse(response.content)["error"]["message"].should eq "Account suspended"
    end

    it "hands a subclassed failure to mcp_audit intact, for `as?` to narrow back" do
      authenticate_as(SpecTokenFailure.new("tok-9", 401, "Invalid token"))
      post_mcp(PING).status.should eq 401

      record = only_record
      record.failure.as?(SpecTokenFailure).try(&.token).should eq "tok-9"
    end
  end

  describe "a body it cannot use" do
    it "400s malformed JSON as -32700 and audits it" do
      response = post_mcp("{oops")
      response.status.should eq 400
      error_code_of(response).should eq -32700

      record = only_record
      record.outcome.should eq "error"
      record.error_code.should eq -32700
      record.rpc_method.should be_nil
      # The caller authenticated before the body was read, so the row names it.
      record.caller.should_not be_nil
    end

    it "400s valid JSON that is not a JSON-RPC request as -32600 and audits it" do
      response = post_mcp("[1,2,3]")
      response.status.should eq 400
      error_code_of(response).should eq -32600

      record = only_record
      record.outcome.should eq "error"
      record.error_code.should eq -32600
    end

    it "400s a mirrored-header mismatch as -32020 and audits it" do
      body = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":) +
             %({"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}})
      response = post_mcp(body, headers: {
        "MCP-Protocol-Version" => "2026-07-28",
        "Mcp-Method"           => "tools/call",
      })
      response.status.should eq 400
      error_code_of(response).should eq -32020

      record = only_record
      record.outcome.should eq "error"
      record.error_code.should eq -32020
      record.rpc_method.should eq "ping"
    end
  end

  describe "what the audit row names" do
    it "attributes the tool a notified tools/call named, from the envelope" do
      Marten::MCP::Registry.register(SpecReadTool.new)
      post_mcp(call_tool_body("spec_read", id: nil)).status.should eq 202

      record = only_record
      record.outcome.should eq "accepted"
      record.tool_name.should eq "spec_read"
    end

    it "attributes no tool to a method that never named one" do
      response = post_mcp(%({"jsonrpc":"2.0","id":1,"method":"ping","params":{"name":"spec_read"}}))
      response.status.should eq 200
      only_record.tool_name.should be_nil
    end

    it "records the arguments of a tools/call" do
      Marten::MCP::Registry.register(SpecReadTool.new)
      post_mcp(call_tool_body("spec_read", arguments: %({"q":"widget"}))).status.should eq 200

      record = only_record
      record.tool_name.should eq "spec_read"
      record.arguments.try(&.["q"]?).try(&.as_s).should eq "widget"
    end

    it "records no arguments for any other method" do
      post_mcp(PING).status.should eq 200
      only_record.arguments.should be_nil
    end
  end

  describe "an insufficient scope" do
    it "403s with the insufficient_scope challenge" do
      Marten::MCP::Registry.register(SpecWriteTool.new)
      response = post_mcp(call_tool_body("spec_write"))
      response.status.should eq 403
      response.headers["WWW-Authenticate"].should eq %(Bearer error="insufficient_scope")
      response.headers["WWW-Authenticate"].to_s.should_not contain "resource_metadata"

      record = only_record
      record.outcome.should eq "denied"
      record.error_code.should eq -32001
      record.tool_name.should eq "spec_write"
    end
  end

  describe "an exception no named branch anticipated" do
    # The property the catch-all rescue exists for: one row per call still
    # holds for what this code did not name.
    it "500s as -32603 and still writes exactly one audit record" do
      Marten::MCP::Registry.register(SpecBoomTool.new)
      response = post_mcp(call_tool_body("spec_boom"))
      response.status.should eq 500
      error_code_of(response).should eq -32603

      record = only_record
      record.outcome.should eq "error"
      record.error_code.should eq -32603
    end
  end

  describe "caching" do
    it "answers JSON that is never cached, whatever the outcome" do
      Marten::MCP::Registry.register(SpecBoomTool.new)
      responses = [
        Marten::Spec.client.get(mcp_path),
        post_mcp(PING),
        post_mcp(%({"jsonrpc":"2.0","method":"notifications/initialized"})),
        post_mcp("{oops"),
        post_mcp(call_tool_body("spec_boom")),
      ]
      responses.each do |response|
        response.content_type.should contain "application/json"
        response.headers["Cache-Control"].should eq "private, no-store"
      end
    end
  end

  describe "a subclass implementing only the two required hooks" do
    it "serves a ping and audits nothing" do
      response = post_mcp(PING, path: bare_path)
      response.status.should eq 200
      JSON.parse(response.content)["result"].should eq JSON.parse("{}")
      audited.size.should eq 0
    end

    # mcp_origin_failure's default is a real check, not a stub.
    it "still refuses a foreign Origin" do
      post_mcp(PING, headers: {"Origin" => "https://evil.example.net"}, path: bare_path)
        .status.should eq 403
    end
  end
end

describe "Marten::MCP::EndpointHandler#mcp_dispatcher" do
  before_each { SpecExtendedHandler.reset! }

  # The seam exists so a consumer can add a JSON-RPC method WITHOUT
  # reimplementing `post` — and therefore without reimplementing the audit
  # contract and the recorded-flag guard, which are the two things most worth
  # not rewriting.
  it "lets a consumer serve a method this shard does not implement" do
    response = Marten::Spec.client.post(
      Marten.routes.reverse("spec_extended"),
      data: %({"jsonrpc":"2.0","id":1,"method":"shop/ping","params":{}}),
      content_type: "application/json")

    response.status.should eq 200
    JSON.parse(response.content)["result"]["shop"].as_s.should eq "ok"
  end

  # The point of the seam, not a bonus: a custom method is audited by the same
  # single code path as a built-in one.
  it "audits a consumer's own method exactly once, like any other call" do
    Marten::Spec.client.post(
      Marten.routes.reverse("spec_extended"),
      data: %({"jsonrpc":"2.0","id":1,"method":"shop/ping","params":{}}),
      content_type: "application/json")

    SpecExtendedHandler.audited.size.should eq 1
    record = SpecExtendedHandler.audited.first
    record.rpc_method.should eq "shop/ping"
    record.outcome.should eq "ok"
  end

  # Delegating to super must leave every built-in method working.
  it "still answers the shard's own methods through the subclass" do
    response = Marten::Spec.client.post(
      Marten.routes.reverse("spec_extended"),
      data: %({"jsonrpc":"2.0","id":1,"method":"ping","params":{}}),
      content_type: "application/json")

    response.status.should eq 200
    SpecExtendedHandler.audited.first.rpc_method.should eq "ping"
  end

  it "still 404s a method neither the subclass nor the shard implements" do
    response = Marten::Spec.client.post(
      Marten.routes.reverse("spec_extended"),
      data: %({"jsonrpc":"2.0","id":1,"method":"nope/nope","params":{}}),
      content_type: "application/json")

    response.status.should eq 404
    JSON.parse(response.content)["error"]["code"].as_i.should eq -32601
  end
end
