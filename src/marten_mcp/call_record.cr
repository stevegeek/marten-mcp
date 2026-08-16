module Marten::MCP
  # Everything the endpoint knows about one request, handed to the audit hook
  # exactly once per call — including the calls that failed before they reached
  # a tool, which are the ones an audit trail exists for.
  #
  # `caller` and `failure` are mutually exclusive: an authenticated request has
  # a caller, a refused one has a failure, and the pre-auth Origin rejection has
  # a failure with no credential behind it.
  struct CallRecord
    getter caller : Caller?
    getter failure : AuthFailure?
    getter ip : String?
    getter rpc_method : String?
    getter tool_name : String?
    # ok | accepted | denied | error. "accepted" is a notification: acknowledged
    # under JSON-RPC's no-reply rule, never executed.
    getter outcome : String
    getter error_code : Int32?
    getter arguments : JSON::Any?
    getter summary : String?
    getter duration_us : Int32
    getter client_name : String?
    getter client_version : String?
    getter protocol_version : String?

    def initialize(
      @outcome : String,
      @duration_us : Int32,
      @caller : Caller? = nil,
      @failure : AuthFailure? = nil,
      @ip : String? = nil,
      @rpc_method : String? = nil,
      @tool_name : String? = nil,
      @error_code : Int32? = nil,
      @arguments : JSON::Any? = nil,
      @summary : String? = nil,
      @client_name : String? = nil,
      @client_version : String? = nil,
      @protocol_version : String? = nil,
    )
    end
  end
end
