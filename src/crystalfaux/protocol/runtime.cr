module Crystalfaux::Protocol
  # The `Runtime` domain: per-page script evaluation and execution contexts.
  # The structs sit in one file because each is a small value type of the
  # same schema section.
  module Runtime
    # The `ObjectType` enum of the Juggler schema.
    Protocol.wire_enum(ObjectType, object: "object", function: "function", undefined: "undefined",
      string: "string", number: "number", boolean: "boolean", symbol: "symbol", bigint: "bigint")
    # The `ObjectSubtype` enum of the Juggler schema.
    Protocol.wire_enum(ObjectSubtype, array: "array", null: "null", node: "node", regexp: "regexp",
      date: "date", map: "map", set: "set", weakmap: "weakmap", weakset: "weakset", error: "error",
      proxy: "proxy", promise: "promise", typedarray: "typedarray")
    # Numbers that JSON cannot carry.
    Protocol.wire_enum(UnserializableValue, infinity: "Infinity", negative_infinity: "-Infinity",
      negative_zero: "-0", nan: "NaN")

    # A value returned by evaluation. With `returnByValue`, *value* holds the
    # value; otherwise *object_id* names a handle in the page. *value* is
    # `nil` for `undefined` and `JSON::Any.new(nil)` for `null`.
    struct RemoteObject
      include Message

      field type : ObjectType?
      field subtype : ObjectSubtype?
      field object_id : String?
      field unserializable_value : UnserializableValue?
      Protocol.any_fields value
    end

    # The `ExceptionDetails` type of the Juggler schema.
    struct ExceptionDetails
      include Message

      field text : String?
      field stack : String?
      Protocol.any_fields value
    end

    # An argument to `CallFunction`: a handle, a special number, or a value.
    struct CallFunctionArgument
      include Message

      field object_id : String?
      field unserializable_value : UnserializableValue?
      Protocol.any_fields value

      def initialize(*, @value : JSON::Any? = nil, @object_id : String? = nil,
                     @unserializable_value : UnserializableValue? = nil)
      end
    end

    # Which frame and world an execution context belongs to. *name* is empty
    # for the frame's default world and the world name for a named world.
    # Upstream Juggler makes the default world the page's main world;
    # Camoufox makes it an isolated sandbox (`FrameTree.js`,
    # `_createIsolatedContext`).
    struct AuxData
      include Message

      field frame_id : String?
      field name : String?
    end

    # The outcome of `Evaluate` and `CallFunction`: a result, or the
    # exception the script threw.
    struct EvaluationResult
      include Message

      field result : RemoteObject?
      field exception_details : ExceptionDetails?
    end

    # Evaluates *expression* in the execution context
    # *execution_context_id*, from `ExecutionContextCreated` (a frame id is
    # not accepted).
    struct Evaluate
      include Message
      include Request(EvaluationResult)
      METHOD = "Runtime.evaluate"

      field execution_context_id : String
      field expression : String
      field return_by_value : Bool?

      def initialize(@execution_context_id : String, @expression : String, @return_by_value : Bool? = nil)
      end
    end

    # Calls *function_declaration*, for example `"(a, b) => a + b"`, with
    # *args*.
    struct CallFunction
      include Message
      include Request(EvaluationResult)
      METHOD = "Runtime.callFunction"

      field execution_context_id : String
      field function_declaration : String
      field return_by_value : Bool?
      field args : Array(CallFunctionArgument)

      def initialize(@execution_context_id : String, @function_declaration : String,
                     @args : Array(CallFunctionArgument) = [] of CallFunctionArgument,
                     @return_by_value : Bool? = nil)
      end
    end

    # Releases the handle *object_id* of *execution_context_id*. Camoufox
    # also releases every handle of a context when the context goes
    # (`additions/juggler/content/Runtime.js`, `disposeObject`).
    struct DisposeObject
      include Message
      include Request(Empty)
      METHOD = "Runtime.disposeObject"

      field execution_context_id : String
      field object_id : String

      def initialize(@execution_context_id : String, @object_id : String)
      end
    end

    # One enumerable own property of an object, from `GetObjectProperties`.
    struct ObjectProperty
      include Message

      field name : String
      field value : RemoteObject
    end

    # Lists the enumerable properties of the handle *object_id*, each value
    # as a new handle in the same context.
    struct GetObjectProperties
      include Message

      # The reply of `GetObjectProperties`.
      struct Result
        include Message

        field properties : Array(ObjectProperty)
      end

      include Request(Result)
      METHOD = "Runtime.getObjectProperties"

      field execution_context_id : String
      field object_id : String

      def initialize(@execution_context_id : String, @object_id : String)
      end
    end

    # The `Runtime.executionContextCreated` event.
    struct ExecutionContextCreated
      include Message
      METHOD = "Runtime.executionContextCreated"

      field execution_context_id : String
      field aux_data : AuxData
    end

    # The `Runtime.executionContextDestroyed` event.
    struct ExecutionContextDestroyed
      include Message
      METHOD = "Runtime.executionContextDestroyed"

      field execution_context_id : String
    end

    # The `Runtime.executionContextsCleared` event.
    struct ExecutionContextsCleared
      include Message
      METHOD = "Runtime.executionContextsCleared"
    end
  end
end
