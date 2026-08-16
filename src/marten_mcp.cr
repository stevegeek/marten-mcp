require "marten"
require "./marten_mcp/settings"
require "./marten_mcp/echo"
require "./marten_mcp/args"
require "./marten_mcp/protocol/versions"
require "./marten_mcp/protocol/envelope"
require "./marten_mcp/protocol/headers"
require "./marten_mcp/caller"
require "./marten_mcp/auth_failure"
require "./marten_mcp/call_record"
require "./marten_mcp/tool"
require "./marten_mcp/registry"
require "./marten_mcp/protocol/dispatcher"
require "./marten_mcp/origin"
require "./marten_mcp/endpoint_handler"

# Model Context Protocol endpoint primitives for Marten.
#
# Provides the wire protocol — JSON-RPC envelope, version negotiation, the
# Streamable HTTP mirrored headers, the dispatcher — and an abstract handler
# implementing the full request lifecycle. Identity, authorization, tenancy and
# auditing are the consuming application's, reached through hooks.
#
# Dual-era and stateless: revision 2026-07-28 alongside 2025-11-25 and
# 2025-06-18, with no sessions and no initialize handshake required.
module Marten::MCP
  VERSION = "0.1.0"

  # Typed accessor for this shard's settings namespace.
  def self.settings : Settings
    Marten.settings.mcp.as(Settings)
  end
end
