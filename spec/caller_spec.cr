require "./spec_helper"

private struct SpecTenantCaller
  include Marten::MCP::Caller

  getter tenant : String

  def initialize(@tenant : String)
  end

  def can?(capability : Symbol) : Bool
    true
  end
end

describe Marten::MCP::Caller do
  it "round-trips a live caller through a call record" do
    caller = SpecTenantCaller.new(tenant: "acme")
    record = Marten::MCP::CallRecord.new(outcome: "ok", duration_us: 10, caller: caller)
    record.caller.as?(SpecTenantCaller).try(&.tenant).should eq "acme"
  end

  it "narrows to nil rather than raising for a caller of a different type" do
    record = Marten::MCP::CallRecord.new(
      outcome: "ok", duration_us: 10, caller: SpecCaller.new(Set{:read}))
    record.caller.as?(SpecTenantCaller).should be_nil
  end
end
