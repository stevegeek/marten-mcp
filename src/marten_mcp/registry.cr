module Marten::MCP
  # The tool catalogue, and a security boundary rather than only a lookup:
  # `visible_for` returns just the tools the caller may actually use, so a
  # read-only token never learns that a delete tool exists. The spec permits
  # this explicitly — the tool set MAY vary by the authorization presented.
  module Registry
    extend self

    ALL = [] of Tool

    def register(tool : Tool) : Nil
      ALL << tool
    end

    def all : Array(Tool)
      ALL
    end

    # Sorted by name: clients cache the tool list and models prompt-cache it,
    # so the order must not wobble between requests.
    def visible_for(caller : Caller) : Array(Tool)
      ALL.select { |tool| caller.can?(tool.capability) }.sort_by(&.name)
    end

    def find(name : String) : Tool?
      ALL.find { |tool| tool.name == name }
    end
  end
end
