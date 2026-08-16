require "./spec_helper"

describe Marten::MCP::Protocol do
  describe ".supported?" do
    it "is true for 2026-07-28" do
      Marten::MCP::Protocol.supported?("2026-07-28").should be_true
    end

    it "is true for 2025-11-25" do
      Marten::MCP::Protocol.supported?("2025-11-25").should be_true
    end

    it "is true for 2025-06-18" do
      Marten::MCP::Protocol.supported?("2025-06-18").should be_true
    end

    it "recognises exactly three revisions" do
      Marten::MCP::Protocol::SUPPORTED.size.should eq 3
    end

    it "is false for an unknown revision" do
      Marten::MCP::Protocol.supported?("1900-01-01").should be_false
    end
  end

  describe ".negotiate" do
    it "returns LEGACY_DEFAULT when nothing was requested" do
      Marten::MCP::Protocol.negotiate(nil).should eq Marten::MCP::Protocol::LEGACY_DEFAULT
    end

    it "echoes a supported revision back" do
      Marten::MCP::Protocol.negotiate(Marten::MCP::Protocol::MODERN).should eq Marten::MCP::Protocol::MODERN
    end

    it "falls back to LEGACY_DEFAULT for an unknown revision" do
      Marten::MCP::Protocol.negotiate("1900-01-01").should eq Marten::MCP::Protocol::LEGACY_DEFAULT
    end
  end
end
