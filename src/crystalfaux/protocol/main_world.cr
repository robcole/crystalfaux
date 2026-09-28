module Crystalfaux::Protocol::Runtime
  # :nodoc:
  #
  # Camoufox's `mw:` route into a frame's main world, the world of the
  # page's own scripts.
  #
  # Camoufox makes the default world of each frame an isolated sandbox. Its
  # `additions/juggler/content/Runtime.js` (`callFunction`,
  # `isMainWorldRequest`) runs a script in the main world only for a
  # `Runtime.callFunction` in Playwright's utility-script shape: a function
  # declaration that contains `utilityScript.evaluate`, and the arguments
  # `[utilityScript, isFunction, returnByValue, expression, argCount]` with
  # the expression prefixed `mw:`. `Runtime.evaluate` with the prefix does
  # not reach the main world. The browser drops the first argument, so a
  # placeholder stands in for the utility script handle.
  #
  # The browser allows this only when the launch config sets
  # `allowMainWorld` to `true`; otherwise the reply is an exception with the
  # text "Main world evaluation is disabled".
  #
  # The value comes back in Playwright's serialized form
  # (`server/isomorphic/utilityScriptSerializers.ts`), which `.decode` turns
  # into JSON.
  module MainWorld
    PREFIX = "mw:"

    FUNCTION_DECLARATION = "(utilityScript, ...args) => utilityScript.evaluate(...args)"

    # The request that evaluates *expression* in the main world of the
    # frame whose default world is *context_id*.
    def self.request(context_id : String, expression : String) : CallFunction
      args = [
        CallFunctionArgument.new(value: JSON::Any.new(nil)),   # utilityScript
        CallFunctionArgument.new(value: JSON::Any.new(false)), # isFunction
        CallFunctionArgument.new(value: JSON::Any.new(true)),  # returnByValue
        CallFunctionArgument.new(value: JSON::Any.new(PREFIX + expression)),
        CallFunctionArgument.new(value: JSON::Any.new(0_i64)), # argCount
      ]
      CallFunction.new(context_id, FUNCTION_DECLARATION, args, return_by_value: true)
    end

    # Decodes a serialized *value*; `nil` is `undefined`.
    #
    # `undefined` and `null` become JSON `null`, `NaN`, `Infinity`,
    # `-Infinity` and `-0` become floats, also inside objects and arrays. A
    # function or symbol becomes `nil` in place, so an object keeps its key.
    # A `Date` or `URL` becomes its ISO or URL string, a `RegExp` becomes `"/pattern/flags"`, and an `Error`
    # becomes an object with its `name`, `message` and `stack`. An object
    # that the value holds twice is repeated.
    #
    # Raises `EvaluationError` for a cycle, a `BigInt`, a typed array and a
    # handle, which JSON cannot carry.
    def self.decode(value : JSON::Any?) : JSON::Any
      return JSON::Any.new(nil) unless value
      Decoder.new.decode(value)
    end

    # Decodes one value. Playwright numbers each object and array (`id`) and
    # writes `{"ref": id}` when it meets one again, so the decoder keeps the
    # finished ones and tells a repeat from a cycle.
    private class Decoder
      @finished = {} of Int64 => JSON::Any
      @open = Set(Int64).new

      def decode(value : JSON::Any) : JSON::Any
        hash = value.as_h?
        return value unless hash
        if special = hash["v"]?
          special_value(special.as_s)
        elsif text = hash["d"]? || hash["u"]?
          text
        elsif regexp = hash["r"]?
          JSON::Any.new("/#{regexp["p"]}/#{regexp["f"]}")
        elsif error = hash["e"]?
          JSON::Any.new({"name" => error["n"], "message" => error["m"], "stack" => error["s"]? || JSON::Any.new(nil)})
        elsif items = hash["a"]?
          container(hash) { JSON::Any.new(items.as_a.map { |item| decode(item) }) }
        elsif entries = hash["o"]?
          container(hash) { object(entries) }
        elsif ref = hash["ref"]?
          reference(ref.as_i64)
        elsif hash.has_key?("bi")
          raise EvaluationError.new("The result is not serializable as JSON: it holds a BigInt")
        else
          raise EvaluationError.new("The result is not serializable as JSON: #{value.to_json}")
        end
      end

      # An entry whose value serialized to undefined, such as a function,
      # has no "v"; its key stays, with `nil`.
      private def object(entries : JSON::Any) : JSON::Any
        JSON::Any.new(entries.as_a.to_h do |entry|
          value = entry["v"]?
          {entry["k"].as_s, value ? decode(value) : JSON::Any.new(nil)}
        end)
      end

      private def special_value(name : String) : JSON::Any
        case name
        when "NaN"       then JSON::Any.new(Float64::NAN)
        when "Infinity"  then JSON::Any.new(Float64::INFINITY)
        when "-Infinity" then JSON::Any.new(-Float64::INFINITY)
        when "-0"        then JSON::Any.new(-0.0)
        else                  JSON::Any.new(nil) # "undefined" and "null"
        end
      end

      private def container(hash : Hash(String, JSON::Any), & : -> JSON::Any) : JSON::Any
        id = hash["id"].as_i64
        @open << id
        result = yield
        @open.delete(id)
        @finished[id] = result
      end

      private def reference(id : Int64) : JSON::Any
        raise EvaluationError.new("The result is not serializable as JSON: it holds a cycle") if @open.includes?(id)
        @finished[id]? || raise EvaluationError.new("The result refers to unknown object #{id}")
      end
    end
  end
end
