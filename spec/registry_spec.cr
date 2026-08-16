require "./spec_helper"

Spec.before_each { Marten::MCP::Registry.all.clear }

private class SpecCaller
  include Marten::MCP::Caller

  def initialize(@capabilities : Set(Symbol))
  end

  def can?(capability : Symbol) : Bool
    @capabilities.includes?(capability)
  end
end

# Named to sort AFTER ReadTool, so a name-order assertion can't pass by
# accident of registration order.
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
    Marten::MCP::ToolResult.new(text: "read")
  end
end

# Named to sort BEFORE ReadTool.
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

describe Marten::MCP::Registry do
  describe ".visible_for" do
    it "hides a tool the caller lacks the capability for" do
      Marten::MCP::Registry.register(ReadTool.new)
      Marten::MCP::Registry.register(WriteTool.new)

      caller = SpecCaller.new(Set{:spec_read})
      Marten::MCP::Registry.visible_for(caller).map(&.name).should eq ["z_read"]
    end

    it "sorts the visible tools by name, not registration order" do
      Marten::MCP::Registry.register(ReadTool.new)
      Marten::MCP::Registry.register(WriteTool.new)

      caller = SpecCaller.new(Set{:spec_read, :spec_write})
      Marten::MCP::Registry.visible_for(caller).map(&.name).should eq ["a_write", "z_read"]
    end

    it "returns nothing for a caller with no matching capability" do
      Marten::MCP::Registry.register(ReadTool.new)

      caller = SpecCaller.new(Set(Symbol).new)
      Marten::MCP::Registry.visible_for(caller).should be_empty
    end
  end

  describe ".find" do
    it "returns nil for an unknown tool name" do
      Marten::MCP::Registry.register(ReadTool.new)
      Marten::MCP::Registry.find("nope").should be_nil
    end

    it "returns the tool for a known name" do
      Marten::MCP::Registry.register(ReadTool.new)
      Marten::MCP::Registry.find("z_read").should be_a(ReadTool)
    end

    it "does not filter by capability — the dispatcher re-checks that before calling" do
      Marten::MCP::Registry.register(WriteTool.new)
      caller_without_write = SpecCaller.new(Set(Symbol).new)

      Marten::MCP::Registry.visible_for(caller_without_write).should be_empty
      Marten::MCP::Registry.find("a_write").should be_a(WriteTool)
    end
  end
end
