require "http/headers"
require "json"

# Typed Juggler messages, written by hand from the vendored schema in
# `protocol/Protocol.js` (Camoufox `additions/juggler/protocol/Protocol.js`).
#
# This module only encodes and decodes. Requests serialize to their `params`;
# results and event params decode from the `JSON::Any` that
# `Juggler::Connection` returns. Waiting, registries and retries belong to the
# browser objects that use these types.
#
# Each request struct has a `METHOD` constant and includes `Request(R)`,
# where `R` is the type of its result. Each event struct has a `METHOD`
# constant. Names and optionality follow `Protocol.js`: a `t.Optional` field
# is left out when `nil`, and a `t.Nullable` field is sent as `null`.
#
# ```
# info = Crystalfaux::Protocol.call(connection, Crystalfaux::Protocol::Browser::GetInfo.new)
# info.version # => "Firefox/152.0.4-beta.31"
#
# connection.on(Crystalfaux::Protocol::Page::EventFired::METHOD, session_id) do |params|
#   event = Crystalfaux::Protocol.decode(Crystalfaux::Protocol::Page::EventFired, params)
#   event.name # => Crystalfaux::Protocol::Page::LifecycleEvent::Load
# end
# ```
#
# Only the methods and events that crystalfaux uses are ported. Not ported:
# the `Heap` and `Accessibility` domains, downloads, video recording and
# screencasts, dialogs, workers, web sockets, bindings, file choosers, touch
# events, emulation overrides other than the viewport, proxies, and
# permissions. Port them from `Protocol.js` when a feature needs them.
module Crystalfaux::Protocol
  # A request whose reply decodes to *R*.
  module Request(R)
    # The Juggler method name, for example `"Browser.getInfo"`.
    def method_name : String
      {{ @type.constant("METHOD") }}
    end

    # Decodes the `result` of this request's reply.
    #
    # Juggler leaves `result` out of the reply when a method returns nothing
    # (Camoufox `additions/juggler/protocol/Dispatcher.js` sends
    # `{id, sessionId, result}` with `result` undefined), and
    # `Juggler::Connection#call` then returns a JSON `null`. For an `Empty`
    # result that decodes as an empty object; for any other result it raises
    # `ProtocolError`.
    def decode_result(result : JSON::Any) : R
      if result.raw.nil?
        raise ProtocolError.new(method_name, "the reply has no result") unless R == Empty
        result = JSON::Any.new({} of String => JSON::Any)
      end
      Protocol.decode(R, result)
    end
  end

  # :nodoc:
  #
  # Includes `JSON::Serializable` and adds the `field` macro. Include it in
  # every protocol struct.
  module Message
    macro included
      include JSON::Serializable
    end

    # Declares a getter for *decl* whose JSON key is its name in lower camel
    # case, or *key* when given. With *emit_null*, a `nil` value is written
    # as `null` instead of being left out; use it for `t.Nullable` fields.
    macro field(decl, key = nil, emit_null = false)
      @[JSON::Field(key: {{ key || decl.var.stringify.camelcase(lower: true) }}, emit_null: {{ emit_null }})]
      getter {{ decl }}
    end
  end

  # :nodoc:
  #
  # Declares `t.Any` fields named *names* as `JSON::Any?` getters. A field
  # that is absent stays `nil` and is left out when encoded; a field that is
  # an explicit JSON `null` decodes as `JSON::Any.new(nil)` and is written
  # back as `null`. Runtime values need both: `undefined` has no `value`,
  # `null` has `"value": null`. Call it once per struct.
  macro any_fields(*names)
    {% for name in names %}
      @[JSON::Field(presence: true)]
      getter {{ name.id }} : JSON::Any?
      @[JSON::Field(ignore: true)]
      @{{ name.id }}_present : Bool = false
    {% end %}

    protected def after_initialize
      {% for name in names %}
        @{{ name.id }} = JSON::Any.new(nil) if @{{ name.id }}_present && @{{ name.id }}.nil?
      {% end %}
    end
  end

  # The result of a method that returns nothing: an empty object.
  struct Empty
    include Message

    def initialize
    end
  end

  # Defines an enum *name* whose members serialize as the protocol strings
  # in *members*. `Protocol.js` spells enum values in several styles
  # (`"load"`, `"DOMContentLoaded"`, `"image/png"`), so each member names its
  # wire string. Decoding an unknown string raises `JSON::ParseException`.
  #
  # ```
  # Protocol.wire_enum(LifecycleEvent, load: "load", dom_content_loaded: "DOMContentLoaded")
  # LifecycleEvent::DomContentLoaded.to_json # => %("DOMContentLoaded")
  # ```
  macro wire_enum(name, **members)
    enum {{ name }}
      {% for member in members.keys %}
        {{ member.id.camelcase }}
      {% end %}

      # The protocol's spelling of this value.
      # Types are written from the root: members such as `String` would
      # shadow them inside the enum.
      def wire_name : ::String
        case self
        {% for member, wire in members %}
          in {{ member.id.camelcase }} then {{ wire }}
        {% end %}
        end
      end

      def to_json(json : ::JSON::Builder) : ::Nil
        json.string(wire_name)
      end

      def self.new(pull : ::JSON::PullParser) : self
        location = pull.location
        string = pull.read_string
        values.find(&.wire_name.==(string)) ||
          raise ::JSON::ParseException.new("Unknown {{ name }} #{string.inspect}", *location)
      end
    end
  end

  # Sends *request* through *connection* to *session_id* (the root session
  # when `nil`) and returns its decoded result.
  #
  # Raises what `Juggler::Connection#call` raises, including the reason of
  # a cancelled *cancellation*, and `JSON::ParseException`
  # when the result does not match the schema.
  def self.call(connection : Juggler::Connection, request : Request(R), session_id : String? = nil,
                timeout : Time::Span = Juggler::Connection::DEFAULT_TIMEOUT,
                cancellation : Juggler::Cancellation? = nil) : R forall R
    request.decode_result(connection.call(request.method_name, request, session_id, timeout, cancellation))
  end

  # Decodes *value*, a result or event params, as *type*.
  def self.decode(type : T.class, value : JSON::Any) : T forall T
    type.from_json(value.to_json)
  end
end
