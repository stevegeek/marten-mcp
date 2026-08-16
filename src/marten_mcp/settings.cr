module Marten::MCP
  # Application settings for the MCP endpoint, exposed under the `mcp`
  # namespace (`Marten.settings.mcp`). Read them through the typed
  # `Marten::MCP.settings` helper.
  class Settings < Marten::Conf::Settings
    namespace :mcp

    # Identifies this server to a client, in the `initialize` result and in
    # `server/discover`'s `_meta`.
    property server_name : String = "marten-mcp"
    property server_version : String = "0.0.0"

    # Free text shown to the model. Nil means the field is OMITTED rather than
    # sent empty — an empty instructions string is worse than no field.
    property instructions : String? = nil

    # Where this shard's log lines land. Set it to the source your application's
    # operators already filter on, so an extracted endpoint does not silently
    # move its logging out from under existing alerts.
    property log_source : String = "marten_mcp"

    # Restores defaults. Used to isolate specs that mutate global settings.
    def reset! : Nil
      @server_name = "marten-mcp"
      @server_version = "0.0.0"
      @instructions = nil
      @log_source = "marten_mcp"
    end
  end
end
