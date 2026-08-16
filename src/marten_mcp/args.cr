module Marten::MCP
  # Typed access to a tool's `arguments` object.
  #
  # Marten::Schema is built for string-keyed form data; tool arguments are
  # already typed JSON, so they read better here. A wrong type or a missing
  # required field raises Invalid, which the dispatcher turns into -32602 with
  # the field named — enough for a model to correct itself and retry.
  struct Args
    class Invalid < Exception
      getter field : String

      def initialize(@field : String, message : String)
        super(message)
      end
    end

    EMPTY = JSON::Any.new({} of String => JSON::Any)

    @raw : JSON::Any

    # `arguments` is caller-controlled JSON, so it can be 5, "x" or null, and
    # every `@raw[key]?` below would then raise. Envelope#arguments already
    # guards its own call site; guarding again here closes the CLASS instead
    # of relying on one caller's invariant — this exact bug class escaped
    # three times on this branch.
    def initialize(raw : JSON::Any)
      @raw = raw.as_h? ? raw : EMPTY
    end

    def string?(key : String) : String?
      value = @raw[key]?
      return nil if value.nil? || value.raw.nil?
      string = value.as_s?
      raise Invalid.new(key, "#{key} must be a string") if string.nil?
      string.presence
    end

    def string(key : String) : String
      string?(key) || raise Invalid.new(key, "#{key} is required")
    end

    def bool?(key : String) : Bool?
      value = @raw[key]?
      return nil if value.nil? || value.raw.nil?
      boolean = value.as_bool?
      raise Invalid.new(key, "#{key} must be true or false") if boolean.nil?
      boolean
    end

    def int?(key : String) : Int32?
      value = @raw[key]?
      return nil if value.nil? || value.raw.nil?
      number = value.as_i64?
      raise Invalid.new(key, "#{key} must be an integer") if number.nil?
      # `.to_i32` is a CHECKED conversion — it raises OverflowError, not
      # Invalid, for anything outside Int32's range. Bounds-check explicitly
      # so an out-of-range value fails the same named-field way a wrong type
      # already does, rather than escaping as an uncaught exception the
      # dispatcher has no rescue clause for. Distinct from `int`'s clamp
      # below on purpose: clamping is a policy choice for a value too large
      # for OUR limit, but a value too large for the TYPE is a malformed
      # argument, and the two need different answers.
      if number < Int32::MIN.to_i64 || number > Int32::MAX.to_i64
        raise Invalid.new(key, "#{key} must fit in a 32-bit integer")
      end
      number.to_i32
    end

    # Clamps rather than raises: a model that asks for a thousand rows should
    # get the maximum and a cursor, not an error it has to reason about.
    def int(key : String, default : Int32, max : Int32) : Int32
      value = int?(key) || default
      return 1 if value < 1
      value > max ? max : value
    end
  end
end
