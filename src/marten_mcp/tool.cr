module Marten::MCP
  # What a tool returns. `structured` is already-serialized JSON (or nil): the
  # shapes vary per tool, and serializing at the edge keeps this struct free
  # of generics.
  struct ToolResult
    getter text : String
    getter structured : String?
    getter is_error : Bool
    getter summary : String?

    def initialize(@text, @structured = nil, @is_error = false, @summary = nil)
    end

    def self.error(text : String) : ToolResult
      new(text: text, structured: nil, is_error: true, summary: "tool error")
    end
  end

  # One action, one capability.
  #
  # `capability` is drawn from the consuming application's capability
  # vocabulary. The registry hides a tool the caller cannot use, and the
  # dispatcher re-checks before calling it: the list is a courtesy, the call
  # check is the gate.
  abstract class Tool
    abstract def name : String
    abstract def title : String
    abstract def description : String
    abstract def capability : Symbol
    abstract def input_schema : String
    abstract def call(caller : Caller, args : Args) : ToolResult

    def output_schema : String?
      nil
    end

    def read_only? : Bool
      true
    end

    # Destructive tools take a two-step confirm (spec §9.1). The seam exists
    # now; the first destructive tool implements it.
    def destructive? : Bool
      false
    end

    def idempotent? : Bool
      read_only?
    end

    def definition_json : String
      String.build do |io|
        io << %({"name":) << name.to_json
        io << %(,"title":) << title.to_json
        io << %(,"description":) << description.to_json
        io << %(,"inputSchema":) << input_schema
        if schema = output_schema
          io << %(,"outputSchema":) << schema
        end
        io << %(,"annotations":{"readOnlyHint":) << read_only?
        io << %(,"destructiveHint":) << destructive?
        io << %(,"idempotentHint":) << idempotent?
        io << %(}})
      end
    end
  end
end
