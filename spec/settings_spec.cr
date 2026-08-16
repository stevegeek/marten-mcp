require "./spec_helper"

describe Marten::MCP::Settings do
  it "defaults the server identity" do
    Marten::MCP.settings.server_name.should eq "marten-mcp"
    Marten::MCP.settings.server_version.should eq "0.0.0"
    Marten::MCP.settings.instructions.should be_nil
    Marten::MCP.settings.log_source.should eq "marten_mcp"
  end

  it "reset! restores every default" do
    Marten::MCP.settings.server_name = "changed"
    Marten::MCP.settings.instructions = "changed"
    Marten::MCP.settings.log_source = "changed"
    Marten::MCP.settings.reset!
    Marten::MCP.settings.server_name.should eq "marten-mcp"
    Marten::MCP.settings.instructions.should be_nil
    Marten::MCP.settings.log_source.should eq "marten_mcp"
  end
end
