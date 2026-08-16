require "./spec_helper"

private def request(headers : ::HTTP::Headers) : Marten::HTTP::Request
  Marten::HTTP::Request.new(::HTTP::Request.new("POST", "/mcp", headers))
end

private def modern_list_envelope : Marten::MCP::Protocol::Envelope
  body = %({"jsonrpc":"2.0","id":1,"method":"tools/list",) +
         %("params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}})
  Marten::MCP::Protocol::Envelope.parse(body).not_nil!
end

private def modern_call_envelope(name : String) : Marten::MCP::Protocol::Envelope
  body = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"#{name}",) +
         %("_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}})
  Marten::MCP::Protocol::Envelope.parse(body).not_nil!
end

private def legacy_envelope : Marten::MCP::Protocol::Envelope
  Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":1,"method":"ping","params":{}})).not_nil!
end

describe Marten::MCP::Protocol::Headers do
  describe ".decode" do
    it "passes a plain value through" do
      Marten::MCP::Protocol::Headers.decode("list_orders").should eq "list_orders"
    end

    it "decodes a =?base64?...?= sentinel" do
      encoded = "=?base64?#{Base64.strict_encode("Hello, 世界")}?="
      Marten::MCP::Protocol::Headers.decode(encoded).should eq "Hello, 世界"
    end

    it "returns the raw value when the sentinel body is not valid base64" do
      Marten::MCP::Protocol::Headers.decode("=?base64?!!!?=").should eq "=?base64?!!!?="
    end
  end

  describe ".mismatch" do
    it "is nil for a legacy envelope regardless of headers" do
      req = request(::HTTP::Headers.new)
      Marten::MCP::Protocol::Headers.mismatch(req, legacy_envelope).should be_nil
    end

    it "reports a missing MCP-Protocol-Version header" do
      req = request(::HTTP::Headers{"Mcp-Method" => "tools/list"})
      Marten::MCP::Protocol::Headers.mismatch(req, modern_list_envelope)
        .should eq "MCP-Protocol-Version header is missing"
    end

    it "reports a MCP-Protocol-Version header that differs from the body" do
      req = request(::HTTP::Headers{"MCP-Protocol-Version" => "2025-11-25", "Mcp-Method" => "tools/list"})
      Marten::MCP::Protocol::Headers.mismatch(req, modern_list_envelope)
        .should eq "MCP-Protocol-Version header does not match the body"
    end

    it "reports a missing Mcp-Method header" do
      req = request(::HTTP::Headers{"MCP-Protocol-Version" => "2026-07-28"})
      Marten::MCP::Protocol::Headers.mismatch(req, modern_list_envelope)
        .should eq "Mcp-Method header is missing"
    end

    it "reports a Mcp-Method header that differs from the body" do
      req = request(::HTTP::Headers{"MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/call"})
      Marten::MCP::Protocol::Headers.mismatch(req, modern_list_envelope)
        .should eq "Mcp-Method header does not match the body"
    end

    it "reports a missing Mcp-Name header on a tools/call" do
      req = request(::HTTP::Headers{"MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/call"})
      Marten::MCP::Protocol::Headers.mismatch(req, modern_call_envelope("list_orders"))
        .should eq "Mcp-Name header is missing"
    end

    it "reports a Mcp-Name header that differs from the body" do
      req = request(::HTTP::Headers{
        "MCP-Protocol-Version" => "2026-07-28",
        "Mcp-Method"           => "tools/call",
        "Mcp-Name"             => "something_else",
      })
      Marten::MCP::Protocol::Headers.mismatch(req, modern_call_envelope("list_orders"))
        .should eq "Mcp-Name header does not match the body"
    end

    it "is nil when every header agrees with the body" do
      req = request(::HTTP::Headers{
        "MCP-Protocol-Version" => "2026-07-28",
        "Mcp-Method"           => "tools/call",
        "Mcp-Name"             => "list_orders",
      })
      Marten::MCP::Protocol::Headers.mismatch(req, modern_call_envelope("list_orders")).should be_nil
    end

    it "is nil for a method with no params.name, once version and method agree" do
      req = request(::HTTP::Headers{"MCP-Protocol-Version" => "2026-07-28", "Mcp-Method" => "tools/list"})
      Marten::MCP::Protocol::Headers.mismatch(req, modern_list_envelope).should be_nil
    end
  end
end
