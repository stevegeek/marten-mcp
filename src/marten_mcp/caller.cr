module Marten::MCP
  # Whoever the endpoint decided is calling. One question, because this is the
  # only question the protocol layer ever asks: the registry asks it to build
  # the tool list, and the dispatcher asks it again before running a tool. The
  # list is a courtesy, the call check is the gate.
  #
  # The capability vocabulary belongs to the consuming application. Crystal
  # cannot construct a Symbol at runtime, so a capability name arriving over the
  # wire only becomes a Symbol if the application already compiled one with that
  # name — which is what makes an unrecognised scope inert rather than a
  # wildcard. This shard never creates symbols, so that property is the
  # consumer's to keep.
  module Caller
    abstract def can?(capability : Symbol) : Bool
  end
end
