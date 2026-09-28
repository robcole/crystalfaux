# Decodes recorded Juggler frames into the typed `Crystalfaux::Protocol`
# structs, encodes them again, and reports every difference.
#
# A sent frame decodes as the request type of its method. A reply decodes as
# the result type of the request with the same id. An event decodes as the
# event type of its method; `#unported_events` collects events with no type.
class JugglerRoundTrip
  alias Protocol = Crystalfaux::Protocol

  macro method_table(*types)
    {
      {% for type in types %}
        {{ type }}::METHOD => {{ type }},
      {% end %}
    }
  end

  REQUESTS = method_table(
    Protocol::Browser::Enable, Protocol::Browser::GetInfo, Protocol::Browser::CreateBrowserContext,
    Protocol::Browser::RemoveBrowserContext, Protocol::Browser::NewPage, Protocol::Browser::Close,
    Protocol::Browser::SetExtraHTTPHeaders, Protocol::Browser::SetRequestInterception,
    Protocol::Browser::SetCookies, Protocol::Browser::ClearCookies, Protocol::Browser::GetCookies,
    Protocol::Page::Navigate, Protocol::Page::Close, Protocol::Page::SetViewportSize,
    Protocol::Page::Screenshot, Protocol::Page::DispatchKeyEvent, Protocol::Page::DispatchMouseEvent,
    Protocol::Page::DispatchWheelEvent, Protocol::Page::InsertText,
    Protocol::Runtime::Evaluate, Protocol::Runtime::CallFunction,
    Protocol::Network::SetRequestInterception, Protocol::Network::SetExtraHTTPHeaders,
    Protocol::Network::AbortInterceptedRequest, Protocol::Network::ResumeInterceptedRequest,
    Protocol::Network::FulfillInterceptedRequest, Protocol::Network::GetResponseBody,
  )

  EVENTS = method_table(
    Protocol::Browser::AttachedToTarget, Protocol::Browser::DetachedFromTarget,
    Protocol::Page::Ready, Protocol::Page::Crashed, Protocol::Page::EventFired,
    Protocol::Page::FrameAttached, Protocol::Page::FrameDetached, Protocol::Page::NavigationStarted,
    Protocol::Page::NavigationCommitted, Protocol::Page::NavigationAborted,
    Protocol::Page::SameDocumentNavigation,
    Protocol::Runtime::ExecutionContextCreated, Protocol::Runtime::ExecutionContextDestroyed,
    Protocol::Runtime::ExecutionContextsCleared,
    Protocol::Network::RequestWillBeSent, Protocol::Network::ResponseReceived,
    Protocol::Network::RequestFinished, Protocol::Network::RequestFailed,
  )

  # Differences, one line each, naming the frame.
  getter failures = [] of String
  # The methods of events that have no typed struct.
  getter unported_events = Set(String).new
  # The methods that were decoded, requests and events.
  getter decoded = Set(String).new

  # The method and params of each sent request, by id.
  @requests = {} of Int64 => {String, JSON::Any}

  def initialize(frames : Array(JugglerFrame))
    frames.each { |frame| check(frame) }
  end

  private def check(frame : JugglerFrame) : Nil
    message = frame.json
    if frame.sent
      check_request(message)
    elsif id = message["id"]?
      check_reply(id.as_i64, message)
    else
      check_event(message)
    end
  rescue ex : JSON::Error
    failures << "#{frame}: #{ex.message}"
  end

  private def check_request(message : JSON::Any) : Nil
    method = message["method"].as_s
    type = REQUESTS[method]? || return failures << "no request type for #{method}"
    params = message["params"]
    @requests[message["id"].as_i64] = {method, params}
    compare(method, params, type.from_json(params.to_json).to_json)
  end

  private def check_reply(id : Int64, message : JSON::Any) : Nil
    method, params = @requests[id]? || return failures << "reply #{id} has no recorded request"
    if error = message["error"]?
      return failures << "#{method} failed: #{error.to_json}"
    end
    request = REQUESTS[method].from_json(params.to_json)
    # Juggler leaves `result` out when a method returns nothing.
    result = message["result"]? || JSON::Any.new({} of String => JSON::Any)
    compare("#{method} result", result, request.decode_result(result).to_json)
  end

  private def check_event(message : JSON::Any) : Nil
    method = message["method"].as_s
    type = EVENTS[method]? || return unported_events << method
    params = message["params"]? || JSON::Any.new({} of String => JSON::Any)
    compare(method, params, type.from_json(params.to_json).to_json)
  end

  private def compare(what : String, original : JSON::Any, encoded : String) : Nil
    decoded << what
    return if normalize(original) == normalize(JSON.parse(encoded))
    failures << "#{what}: #{original.to_json} became #{encoded}"
  end

  # Makes `1` and `1.0` equal: Juggler writes whole numbers without a
  # fraction, and a `Float64` field writes them with one.
  private def normalize(value : JSON::Any) : JSON::Any
    if hash = value.as_h?
      JSON::Any.new(hash.transform_values { |item| normalize(item) })
    elsif array = value.as_a?
      JSON::Any.new(array.map { |item| normalize(item) })
    elsif number = value.as_i64?
      JSON::Any.new(number.to_f)
    else
      value
    end
  end
end
