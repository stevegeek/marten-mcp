module Marten::MCP
  # Caps a caller-supplied string that we reflect back — a method name, a tool
  # name, a cursor, a tag. Every one of them reaches both a JSON-RPC error
  # message and an audit row, so an uncapped 3 000-character argument comes
  # back whole and is stored whole. Correctly escaped either way; this bounds
  # size, not content.
  module Echo
    extend self

    MAX = 100

    def cap(value : String) : String
      value.size > MAX ? "#{value[0, MAX]}…" : value
    end
  end
end
