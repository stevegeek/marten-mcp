require "./spec_helper"

describe Marten::MCP::Protocol::Envelope do
  describe ".parse" do
    it "parses a legacy request, with modern? false" do
      envelope = Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":1,"method":"ping","params":{}}))
      envelope.should_not be_nil
      envelope.not_nil!.modern?.should be_false
    end

    it "is modern? when the body carries a _meta protocol version" do
      body = %({"jsonrpc":"2.0","id":1,"method":"ping",) +
             %("params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}})
      envelope = Marten::MCP::Protocol::Envelope.parse(body).not_nil!
      envelope.modern?.should be_true
      envelope.declared_version.should eq "2026-07-28"
    end

    it "extracts the client name and version from _meta clientInfo" do
      body = %({"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{) +
             %("io.modelcontextprotocol/protocolVersion":"2026-07-28",) +
             %("io.modelcontextprotocol/clientInfo":{"name":"Acme","version":"3.2"}}}})
      envelope = Marten::MCP::Protocol::Envelope.parse(body).not_nil!
      envelope.client_name.should eq "Acme"
      envelope.client_version.should eq "3.2"
    end

    it "returns nil for a JSON array" do
      Marten::MCP::Protocol::Envelope.parse(%([{"jsonrpc":"2.0","id":1,"method":"ping"}])).should be_nil
    end

    it "returns nil for a bare scalar" do
      Marten::MCP::Protocol::Envelope.parse("5").should be_nil
    end

    it "returns nil for a missing method" do
      Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":1,"params":{}})).should be_nil
    end

    it "returns nil for an array-valued params" do
      Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":1,"method":"ping","params":[1,2,3]})).should be_nil
    end
  end

  describe "#notification?" do
    it "is true for a missing id" do
      envelope = Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","method":"notifications/x","params":{}})).not_nil!
      envelope.notification?.should be_true
    end

    it "is true for an explicit JSON null id" do
      envelope = Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":null,"method":"ping","params":{}})).not_nil!
      envelope.notification?.should be_true
    end

    it "is false when an id is present" do
      envelope = Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":1,"method":"ping","params":{}})).not_nil!
      envelope.notification?.should be_false
    end
  end

  describe "#arguments" do
    it "returns the arguments object when present" do
      body = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"a":1}}})
      envelope = Marten::MCP::Protocol::Envelope.parse(body).not_nil!
      envelope.arguments.as_h.should eq({"a" => JSON::Any.new(1_i64)})
    end

    it "returns empty for a non-object arguments value" do
      body = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":5}})
      envelope = Marten::MCP::Protocol::Envelope.parse(body).not_nil!
      envelope.arguments.as_h.should be_empty
    end

    it "returns empty when arguments is absent" do
      body = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x"}})
      envelope = Marten::MCP::Protocol::Envelope.parse(body).not_nil!
      envelope.arguments.as_h.should be_empty
    end
  end

  describe "#tool_name" do
    it "returns the params.name value" do
      body = %({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_orders"}})
      envelope = Marten::MCP::Protocol::Envelope.parse(body).not_nil!
      envelope.tool_name.should eq "list_orders"
    end

    it "returns nil when params has no name" do
      envelope = Marten::MCP::Protocol::Envelope.parse(%({"jsonrpc":"2.0","id":1,"method":"ping","params":{}})).not_nil!
      envelope.tool_name.should be_nil
    end
  end
end
