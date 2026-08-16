require "./spec_helper"

describe Marten::MCP::Echo do
  it "returns a short value untouched" do
    Marten::MCP::Echo.cap("tools/list").should eq "tools/list"
  end

  it "caps a long value and marks the truncation" do
    capped = Marten::MCP::Echo.cap("x" * 500)
    capped.size.should eq 101
    capped.should end_with "…"
  end

  it "leaves a value of exactly the maximum length alone" do
    Marten::MCP::Echo.cap("y" * 100).should eq "y" * 100
  end
end
