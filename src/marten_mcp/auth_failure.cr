module Marten::MCP
  # Why authentication refused, and with what HTTP status.
  #
  # A class rather than a struct so a consumer can subclass it and carry more —
  # typically the credential that was presented, for the audit row that has to
  # answer "is the token I revoked still being used?". This shard never reads
  # those additions; they travel to the audit hook inside CallRecord#failure,
  # where the consumer narrows the type back with `as?`.
  class AuthFailure
    getter status : Int32
    getter message : String

    def initialize(@status : Int32, @message : String)
    end
  end
end
