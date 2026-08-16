require "./spec_helper"

private class SpecTokenFailure < Marten::MCP::AuthFailure
  getter token_label : String

  def initialize(status : Int32, message : String, @token_label : String)
    super(status, message)
  end
end

describe Marten::MCP::AuthFailure do
  it "carries a subclass through a call record" do
    failure = SpecTokenFailure.new(401, "Invalid token", "laptop")
    record = Marten::MCP::CallRecord.new(outcome: "denied", duration_us: 10, failure: failure)
    record.failure.as?(SpecTokenFailure).try(&.token_label).should eq "laptop"
  end

  it "narrows to nil rather than raising for a plain failure" do
    record = Marten::MCP::CallRecord.new(
      outcome: "denied", duration_us: 10,
      failure: Marten::MCP::AuthFailure.new(403, "Origin not allowed"))
    record.failure.as?(SpecTokenFailure).should be_nil
  end
end
