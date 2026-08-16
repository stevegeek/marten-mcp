require "./spec_helper"

# read_only? true (default), no output schema, idempotent? not overridden.
private class MinimalSpecTool < Marten::MCP::Tool
  def name : String
    "spec_minimal"
  end

  def title : String
    "Spec Minimal"
  end

  def description : String
    "A minimal spec tool with no output schema."
  end

  def capability : Symbol
    :spec_read
  end

  def input_schema : String
    %({"type":"object","properties":{}})
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(text: "ok")
  end
end

# read_only? false, idempotent? not overridden — should follow read_only? down to false.
private class WritingSpecTool < Marten::MCP::Tool
  def name : String
    "spec_writing"
  end

  def title : String
    "Spec Writing"
  end

  def description : String
    "A spec tool that writes and does not override idempotent?."
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

# read_only? false, destructive? true, idempotent? overridden to true, has an
# output schema — exercises every field definition_json can emit.
private class FullSpecTool < Marten::MCP::Tool
  def name : String
    "spec_full"
  end

  def title : String
    "Spec Full"
  end

  def description : String
    "A spec tool with an output schema and overridden hints."
  end

  def capability : Symbol
    :spec_write
  end

  def input_schema : String
    %({"type":"object","properties":{"id":{"type":"string"}},"required":["id"]})
  end

  def output_schema : String?
    %({"type":"object","properties":{"ok":{"type":"boolean"}}})
  end

  def read_only? : Bool
    false
  end

  def destructive? : Bool
    true
  end

  def idempotent? : Bool
    true
  end

  def call(caller : Marten::MCP::Caller, args : Marten::MCP::Args) : Marten::MCP::ToolResult
    Marten::MCP::ToolResult.new(text: "done")
  end
end

describe Marten::MCP::Tool do
  describe "#definition_json" do
    it "emits the exact field order for a tool without an output schema" do
      MinimalSpecTool.new.definition_json.should eq(
        %({"name":"spec_minimal","title":"Spec Minimal",) +
        %("description":"A minimal spec tool with no output schema.",) +
        %("inputSchema":{"type":"object","properties":{}},) +
        %("annotations":{"readOnlyHint":true,"destructiveHint":false,"idempotentHint":true}})
      )
    end

    it "emits the exact field order with outputSchema between inputSchema and annotations" do
      FullSpecTool.new.definition_json.should eq(
        %({"name":"spec_full","title":"Spec Full",) +
        %("description":"A spec tool with an output schema and overridden hints.",) +
        %("inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]},) +
        %("outputSchema":{"type":"object","properties":{"ok":{"type":"boolean"}}},) +
        %("annotations":{"readOnlyHint":false,"destructiveHint":true,"idempotentHint":true}})
      )
    end

    it "parses as valid JSON carrying all three annotation hints" do
      parsed = JSON.parse(FullSpecTool.new.definition_json)
      parsed["name"].as_s.should eq "spec_full"
      parsed["annotations"]["readOnlyHint"].as_bool.should be_false
      parsed["annotations"]["destructiveHint"].as_bool.should be_true
      parsed["annotations"]["idempotentHint"].as_bool.should be_true
    end

    it "omits outputSchema entirely when the tool has none" do
      parsed = JSON.parse(MinimalSpecTool.new.definition_json)
      parsed.as_h.has_key?("outputSchema").should be_false
    end

    it "includes outputSchema when the tool defines one" do
      parsed = JSON.parse(FullSpecTool.new.definition_json)
      parsed["outputSchema"]?.should_not be_nil
      parsed["outputSchema"]["properties"]["ok"]["type"].as_s.should eq "boolean"
    end
  end

  describe "#idempotent?" do
    it "follows read_only? by default when read_only? is true" do
      MinimalSpecTool.new.idempotent?.should be_true
    end

    it "follows read_only? by default when read_only? is false" do
      WritingSpecTool.new.idempotent?.should be_false
    end

    it "can be overridden independently of read_only?" do
      tool = FullSpecTool.new
      tool.read_only?.should be_false
      tool.idempotent?.should be_true
    end
  end
end

describe Marten::MCP::ToolResult do
  describe ".error" do
    it "sets is_error and the tool error summary" do
      result = Marten::MCP::ToolResult.error("boom")
      result.text.should eq "boom"
      result.is_error.should be_true
      result.summary.should eq "tool error"
      result.structured.should be_nil
    end
  end
end
