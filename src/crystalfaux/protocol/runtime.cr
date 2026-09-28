module Crystalfaux::Protocol
  # The `Runtime` domain: per-page script evaluation and execution contexts.
  # The structs sit in one file because each is a small value type of the
  # same schema section.
  module Runtime
    Protocol.wire_enum(ObjectType, object: "object", function: "function", undefined: "undefined",
      string: "string", number: "number", boolean: "boolean", symbol: "symbol", bigint: "bigint")
    Protocol.wire_enum(ObjectSubtype, array: "array", null: "null", node: "node", regexp: "regexp",
      date: "date", map: "map", set: "set", weakmap: "weakmap", weakset: "weakset", error: "error",
      proxy: "proxy", promise: "promise", typedarray: "typedarray")
    # Numbers that JSON cannot carry.
    Protocol.wire_enum(UnserializableValue, infinity: "Infinity", negative_infinity: "-Infinity",
      negative_zero: "-0", nan: "NaN")

    # A value returned by evaluation. With `returnByValue`, *value* holds the
    # value; otherwise *object_id* names a handle in the page.
    struct RemoteObject
      include Message

      field type : ObjectType?
      field subtype : ObjectSubtype?
      field object_id : String?
      field unserializable_value : UnserializableValue?
      field value : JSON::Any?
    end

    struct ExceptionDetails
      include Message

      field text : String?
      field stack : String?
      field value : JSON::Any?
    end

    # An argument to `CallFunction`: a handle, a special number, or a value.
    struct CallFunctionArgument
      include Message

      field object_id : String?
      field unserializable_value : UnserializableValue?
      field value : JSON::Any?

      def initialize(*, @value : JSON::Any? = nil, @object_id : String? = nil,
                     @unserializable_value : UnserializableValue? = nil)
      end
    end

    # Which frame and world an execution context belongs to. *name* is empty
    # for the page's main world and the world name for an isolated world.
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

    struct ExecutionContextCreated
      include Message
      METHOD = "Runtime.executionContextCreated"

      field execution_context_id : String
      field aux_data : AuxData
    end

    struct ExecutionContextDestroyed
      include Message
      METHOD = "Runtime.executionContextDestroyed"

      field execution_context_id : String
    end

    struct ExecutionContextsCleared
      include Message
      METHOD = "Runtime.executionContextsCleared"
    end
  end
end
