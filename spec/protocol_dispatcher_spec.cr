require "./spec_helper"

Spec.before_each { Marten::MCP::Registry.all.clear }

# A consumer's server identity. Arbitrary values — what matters is that they
# are NOT the shard's defaults, so a body built from the defaults instead of
# from the settings fails loudly.
APP_SERVER_NAME    = "acme-shop"
APP_SERVER_VERSION = "1.0.0"
APP_INSTRUCTIONS   = "Back-office tools for the Acme shop. " \
                     "Every tool acts on one account, fixed by the access token."

# Byte-for-byte, the two identity bodies as a NamedTuple literal of the same
# shape serializes them. Derived by running that literal through `.to_json`,
# not typed from memory — these methods build their JSON by hand, so the
# golden text is what pins the hand-built output. Compared as raw strings on
# purpose: field order is part of the contract, because clients and model
# prompt caches key on the exact bytes, and a parsed-field assertion would pass
# happily while the order moved. The same blind spot let a tools/list body ship
# without ttlMs and cacheScope past a green suite.
GOLDEN_INITIALIZE_BODY = %({"protocolVersion":"2026-07-28","capabilities":{"tools":{}},"serverInfo":{"name":"acme-shop","version":"1.0.0"},"instructions":"Back-office tools for the Acme shop. Every tool acts on one account, fixed by the access token."})

GOLDEN_DISCOVER_BODY = %({"resultType":"complete","ttlMs":3600000,"cacheScope":"private","supportedVersions":["2026-07-28","2025-11-25","2025-06-18"],"capabilities":{"tools":{}},"instructions":"Back-office tools for the Acme shop. Every tool acts on one account, fixed by the access token.","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"acme-shop","version":"1.0.0"}}})

private def use_app_identity : Nil
  Marten::MCP.settings.server_name = APP_SERVER_NAME
  Marten::MCP.settings.server_version = APP_SERVER_VERSION
  Marten::MCP.settings.instructions = APP_INSTRUCTIONS
end

# `id` is raw JSON text: nil omits the member entirely (a notification),
# "null" writes an explicit null. `version` goes in params._meta, which is the
# one thing that makes an envelope modern.
private def envelope(
  method : String,
  id : String? = "1",
  params : String = "{}",
  version : String? = nil,
) : Marten::MCP::Protocol::Envelope
  if version
    inner = params.lchop('{').rchop('}').strip
    meta = %("_meta":{"io.modelcontextprotocol/protocolVersion":#{version.to_json}})
    params = inner.empty? ? "{#{meta}}" : "{#{meta},#{inner}}"
  end
  id_member = id.nil? ? "" : %("id":#{id},)
  body = %({"jsonrpc":"2.0",#{id_member}"method":#{method.to_json},"params":#{params}})
  Marten::MCP::Protocol::Envelope.parse(body).not_nil!
end

private def result_of(payload : String) : JSON::Any
  JSON.parse(payload)["result"]
end

private def error_of(payload : String) : JSON::Any
  JSON.parse(payload)["error"]
end

private class SpecCaller
  include Marten::MCP::Caller

  def initialize(@capabilities : Set(Symbol))
  end

  def can?(capability : Symbol) : Bool
    @capabilities.includes?(capability)
  end
end

# Sorts AFTER WriteTool by name, and registers BEFORE it, so a name-order
# assertion cannot pass by accident of registration order.
private class ReadTool < Marten::MCP::Tool
  def name : String
    "z_read"
  end

  def title : String
    "Z Read"
  end

  def description : String
    "Reads something."
  end

  def capability : Symbol
    :spec_read
  end

  def input_schema : String
    %({"type":"object","properties":{}})
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(
      text: "read ok",
      structured: %({"rows":1}),
      summary: "read 1 row")
  end
end

private class WriteTool < Marten::MCP::Tool
  def name : String
    "a_write"
  end

  def title : String
    "A Write"
  end

  def description : String
    "Writes something."
  end

  def capability : Symbol
    :spec_write
  end

  def input_schema : String
    %({"type":"object","properties":{}})
  end

  def read_only? : Bool
    false
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(text: "written")
  end
end

private class StrictTool < Marten::MCP::Tool
  def name : String
    "strict"
  end

  def title : String
    "Strict"
  end

  def description : String
    "Requires a slug."
  end

  def capability : Symbol
    :spec_read
  end

  def input_schema : String
    %({"type":"object","properties":{"slug":{"type":"string"}},"required":["slug"]})
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(text: args.string("slug"))
  end
end

private class FailingTool < Marten::MCP::Tool
  def name : String
    "failing"
  end

  def title : String
    "Failing"
  end

  def description : String
    "Always reports a tool-level error."
  end

  def capability : Symbol
    :spec_read
  end

  def input_schema : String
    %({"type":"object","properties":{}})
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.error("the kitchen is closed")
  end
end

private def reader : SpecCaller
  SpecCaller.new(Set{:spec_read})
end

private def dispatcher(caller : Marten::MCP::Caller = reader) : Marten::MCP::Protocol::Dispatcher
  Marten::MCP::Protocol::Dispatcher.new(caller)
end

describe Marten::MCP::Protocol::Dispatcher do
  describe "ping" do
    it "answers a legacy caller with a bare empty result" do
      outcome = dispatcher.call(envelope("ping"))

      outcome.status.should eq 200
      outcome.outcome.should eq "ok"
      outcome.payload.should eq %({"jsonrpc":"2.0","id":1,"result":{}})
    end

    it "answers a modern caller with resultType" do
      outcome = dispatcher.call(envelope("ping", version: "2026-07-28"))

      outcome.payload.should eq %({"jsonrpc":"2.0","id":1,"result":{"resultType":"complete"}})
    end
  end

  describe "version negotiation" do
    it "rejects an unsupported declared version with -32022 and lists what it speaks" do
      outcome = dispatcher.call(envelope("ping", version: "1999-01-01"))

      outcome.status.should eq 400
      outcome.outcome.should eq "error"
      outcome.error_code.should eq -32022
      error = error_of(outcome.payload)
      error["code"].as_i.should eq -32022
      error["message"].as_s.should eq "Unsupported protocol version"
      error["data"]["supported"].as_a.map(&.as_s).should eq [
        "2026-07-28", "2025-11-25", "2025-06-18",
      ]
      error["data"]["requested"].as_s.should eq "1999-01-01"
    end

    it "checks the version BEFORE the notification rule, so a bad-version notification still 400s" do
      outcome = dispatcher.call(envelope("notifications/initialized", id: nil, version: "1999-01-01"))

      outcome.status.should eq 400
      outcome.error_code.should eq -32022
    end
  end

  describe "notifications" do
    it "answers an id-less message with 202 and no body" do
      outcome = dispatcher.call(envelope("notifications/cancelled", id: nil))

      outcome.status.should eq 202
      outcome.outcome.should eq "ok"
      outcome.payload.should eq ""
    end

    it "treats an explicit null id as a notification too" do
      outcome = dispatcher.call(envelope("notifications/cancelled", id: "null"))

      outcome.status.should eq 202
      outcome.payload.should eq ""
    end
  end

  describe "unknown methods" do
    it "answers 404 with -32601" do
      outcome = dispatcher.call(envelope("tools/teleport"))

      outcome.status.should eq 404
      outcome.outcome.should eq "error"
      outcome.error_code.should eq -32601
      error_of(outcome.payload)["message"].as_s.should eq "Method not found: tools/teleport"
    end

    it "caps the echoed method name" do
      outcome = dispatcher.call(envelope("m" * 300))

      message = error_of(outcome.payload)["message"].as_s
      message.should eq "Method not found: #{"m" * 100}…"
    end
  end

  describe "initialize" do
    it "serializes byte-for-byte what the app served" do
      use_app_identity
      outcome = dispatcher.call(
        envelope("initialize", params: %({"protocolVersion":"2026-07-28"})))

      outcome.status.should eq 200
      outcome.payload.should eq %({"jsonrpc":"2.0","id":1,"result":#{GOLDEN_INITIALIZE_BODY}})
    end

    it "negotiates down to LEGACY_DEFAULT for a version it does not speak" do
      outcome = dispatcher.call(
        envelope("initialize", params: %({"protocolVersion":"1999-01-01"})))

      result_of(outcome.payload)["protocolVersion"].as_s.should eq "2025-06-18"
    end

    it "negotiates to LEGACY_DEFAULT when the client proposes nothing" do
      outcome = dispatcher.call(envelope("initialize"))

      result_of(outcome.payload)["protocolVersion"].as_s.should eq "2025-06-18"
    end

    it "omits instructions entirely when the setting is nil" do
      Marten::MCP.settings.instructions.should be_nil
      outcome = dispatcher.call(envelope("initialize"))

      outcome.payload.should_not contain "instructions"
      result_of(outcome.payload).as_h.keys.should eq [
        "protocolVersion", "capabilities", "serverInfo",
      ]
    end

    it "includes instructions when the setting is set" do
      Marten::MCP.settings.instructions = "Be brief."
      outcome = dispatcher.call(envelope("initialize"))

      result_of(outcome.payload)["instructions"].as_s.should eq "Be brief."
    end

    it "reads the server identity from settings" do
      Marten::MCP.settings.server_name = "other"
      Marten::MCP.settings.server_version = "9.9.9"
      outcome = dispatcher.call(envelope("initialize"))

      server_info = result_of(outcome.payload)["serverInfo"]
      server_info["name"].as_s.should eq "other"
      server_info["version"].as_s.should eq "9.9.9"
    end

    it "carries no resultType, even for a modern caller — initialize is legacy-only" do
      outcome = dispatcher.call(envelope("initialize", version: "2026-07-28"))

      result_of(outcome.payload).as_h.has_key?("resultType").should be_false
    end
  end

  describe "server/discover" do
    it "serializes byte-for-byte what the app served" do
      use_app_identity
      outcome = dispatcher.call(envelope("server/discover"))

      outcome.status.should eq 200
      outcome.payload.should eq %({"jsonrpc":"2.0","id":1,"result":#{GOLDEN_DISCOVER_BODY}})
    end

    it "carries the cache hints, the supported versions and the settings-driven _meta" do
      Marten::MCP.settings.server_name = "other"
      Marten::MCP.settings.server_version = "9.9.9"
      result = result_of(dispatcher.call(envelope("server/discover")).payload)

      result["resultType"].as_s.should eq "complete"
      result["ttlMs"].as_i.should eq 3_600_000
      result["cacheScope"].as_s.should eq "private"
      result["supportedVersions"].as_a.map(&.as_s).should eq [
        "2026-07-28", "2025-11-25", "2025-06-18",
      ]
      server_info = result["_meta"]["io.modelcontextprotocol/serverInfo"]
      server_info["name"].as_s.should eq "other"
      server_info["version"].as_s.should eq "9.9.9"
    end

    it "omits instructions when the setting is nil, keeping every other field in order" do
      result_of(dispatcher.call(envelope("server/discover")).payload).as_h.keys.should eq [
        "resultType", "ttlMs", "cacheScope", "supportedVersions", "capabilities", "_meta",
      ]
    end

    it "puts instructions between capabilities and _meta when set" do
      Marten::MCP.settings.instructions = "Be brief."
      result_of(dispatcher.call(envelope("server/discover")).payload).as_h.keys.should eq [
        "resultType", "ttlMs", "cacheScope", "supportedVersions", "capabilities",
        "instructions", "_meta",
      ]
    end

    it "answers a legacy caller the same body — discover does not route through result" do
      use_app_identity
      legacy = dispatcher.call(envelope("server/discover"))
      modern = dispatcher.call(envelope("server/discover", version: "2026-07-28"))

      legacy.payload.should eq modern.payload
    end
  end

  describe "tools/list" do
    it "carries ttlMs and cacheScope for a modern caller" do
      Marten::MCP::Registry.register(ReadTool.new)
      result = result_of(dispatcher.call(envelope("tools/list", version: "2026-07-28")).payload)

      result["ttlMs"].as_i.should eq 300_000
      result["cacheScope"].as_s.should eq "private"
    end

    it "puts resultType and the cache hints before the tools" do
      Marten::MCP::Registry.register(ReadTool.new)
      result = result_of(dispatcher.call(envelope("tools/list", version: "2026-07-28")).payload)

      result.as_h.keys.should eq ["resultType", "ttlMs", "cacheScope", "tools"]
    end

    it "sends a legacy caller no modern-only fields" do
      Marten::MCP::Registry.register(ReadTool.new)
      result = result_of(dispatcher.call(envelope("tools/list")).payload)

      result.as_h.keys.should eq ["tools"]
    end

    it "lists only the tools the caller can use, sorted by name" do
      Marten::MCP::Registry.register(ReadTool.new)
      Marten::MCP::Registry.register(WriteTool.new)
      Marten::MCP::Registry.register(StrictTool.new)

      both = SpecCaller.new(Set{:spec_read, :spec_write})
      result = result_of(dispatcher(both).call(envelope("tools/list")).payload)
      result["tools"].as_a.map { |tool| tool["name"].as_s }.should eq [
        "a_write", "strict", "z_read",
      ]
    end

    it "hides a tool the caller lacks the capability for" do
      Marten::MCP::Registry.register(ReadTool.new)
      Marten::MCP::Registry.register(WriteTool.new)

      payload = dispatcher.call(envelope("tools/list")).payload
      result_of(payload)["tools"].as_a.map { |tool| tool["name"].as_s }.should eq ["z_read"]
      payload.should_not contain "a_write"
    end

    it "returns an empty list rather than failing when nothing is visible" do
      Marten::MCP::Registry.register(WriteTool.new)

      result_of(dispatcher.call(envelope("tools/list")).payload)["tools"].as_a.should be_empty
    end
  end

  describe "tools/call" do
    it "rejects a call with no tool name" do
      outcome = dispatcher.call(envelope("tools/call"))

      outcome.status.should eq 400
      outcome.outcome.should eq "error"
      outcome.error_code.should eq -32602
      outcome.tool_name.should be_nil
      error_of(outcome.payload)["message"].as_s.should eq "Missing tool name"
    end

    it "rejects an unknown tool name, echoing it" do
      outcome = dispatcher.call(envelope("tools/call", params: %({"name":"nope"})))

      outcome.status.should eq 400
      outcome.error_code.should eq -32602
      outcome.tool_name.should eq "nope"
      error_of(outcome.payload)["message"].as_s.should eq "Unknown tool: nope"
    end

    it "caps the echoed unknown tool name" do
      long = "n" * 300
      outcome = dispatcher.call(envelope("tools/call", params: %({"name":#{long.to_json}})))

      error_of(outcome.payload)["message"].as_s.should eq "Unknown tool: #{"n" * 100}…"
    end

    it "denies a tool the caller lacks, with the insufficient-scope challenge" do
      Marten::MCP::Registry.register(WriteTool.new)
      outcome = dispatcher.call(envelope("tools/call", params: %({"name":"a_write"})))

      outcome.status.should eq 403
      outcome.outcome.should eq "denied"
      outcome.error_code.should eq -32001
      outcome.tool_name.should eq "a_write"
      outcome.challenge.should eq %(Bearer error="insufficient_scope")
    end

    it "tells a denied caller nothing about the tool beyond the name it asked for" do
      Marten::MCP::Registry.register(WriteTool.new)
      payload = dispatcher.call(envelope("tools/call", params: %({"name":"a_write"}))).payload

      error_of(payload)["message"].as_s.should eq "Insufficient scope for a_write"
      payload.should_not contain "A Write"
      payload.should_not contain "Writes something."
      payload.should_not contain "spec_write"
    end

    it "turns Args::Invalid into -32602 naming the field" do
      Marten::MCP::Registry.register(StrictTool.new)
      outcome = dispatcher.call(envelope("tools/call", params: %({"name":"strict"})))

      outcome.status.should eq 400
      outcome.outcome.should eq "error"
      outcome.error_code.should eq -32602
      outcome.tool_name.should eq "strict"
      error_of(outcome.payload)["message"].as_s.should eq "Invalid params: slug is required"
    end

    it "wraps a successful result in content and passes structuredContent through" do
      Marten::MCP::Registry.register(ReadTool.new)
      outcome = dispatcher.call(envelope("tools/call", params: %({"name":"z_read"})))

      outcome.status.should eq 200
      outcome.outcome.should eq "ok"
      outcome.tool_name.should eq "z_read"
      outcome.summary.should eq "read 1 row"
      result = result_of(outcome.payload)
      result["content"].as_a.size.should eq 1
      result["content"][0]["type"].as_s.should eq "text"
      result["content"][0]["text"].as_s.should eq "read ok"
      result["structuredContent"]["rows"].as_i.should eq 1
      result["isError"].as_bool.should be_false
    end

    it "omits structuredContent when the tool set none" do
      Marten::MCP::Registry.register(WriteTool.new)
      both = SpecCaller.new(Set{:spec_read, :spec_write})
      outcome = dispatcher(both).call(envelope("tools/call", params: %({"name":"a_write"})))

      result_of(outcome.payload).as_h.has_key?("structuredContent").should be_false
    end

    it "adds resultType for a modern caller and not for a legacy one" do
      Marten::MCP::Registry.register(ReadTool.new)
      params = %({"name":"z_read"})

      modern = dispatcher.call(envelope("tools/call", params: params, version: "2026-07-28"))
      legacy = dispatcher.call(envelope("tools/call", params: params))

      result_of(modern.payload).as_h.keys.first.should eq "resultType"
      result_of(legacy.payload).as_h.has_key?("resultType").should be_false
    end

    it "reports a tool-level error as outcome error over HTTP 200" do
      Marten::MCP::Registry.register(FailingTool.new)
      outcome = dispatcher.call(envelope("tools/call", params: %({"name":"failing"})))

      outcome.status.should eq 200
      outcome.outcome.should eq "error"
      outcome.error_code.should be_nil
      outcome.tool_name.should eq "failing"
      result = result_of(outcome.payload)
      result["isError"].as_bool.should be_true
      result["content"][0]["text"].as_s.should eq "the kitchen is closed"
    end
  end
end
