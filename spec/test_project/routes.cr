Marten.routes.draw do
  path "/mcp", SpecEndpointHandler, name: "spec_mcp"
  path "/bare", SpecBareHandler, name: "spec_bare"
  path "/extended", SpecExtendedHandler, name: "spec_extended"
end
