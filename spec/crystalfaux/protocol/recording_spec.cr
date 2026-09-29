require "../../spec_helper"
require "http/server"

private alias Protocol = Crystalfaux::Protocol

private FIXTURE          = File.expand_path("../../fixtures/juggler/probe.frames", __DIR__)
private ELEMENTS_FIXTURE = File.expand_path("../../fixtures/juggler/elements.frames", __DIR__)

# Serves one page that sets a cookie, so the probe records network events.
private def start_page_server : {HTTP::Server, String}
  server = HTTP::Server.new do |context|
    next context.response.respond_with_status(:not_found) unless context.request.path == "/"
    context.response.content_type = "text/html"
    context.response.headers["Set-Cookie"] = "probe=1; Path=/"
    context.response.print "<!DOCTYPE html><title>network</title><p>crystalfaux</p>"
  end
  address = server.bind_tcp("127.0.0.1", 0)
  spawn { server.listen }
  {server, "http://#{address}/"}
end

# Drives the real browser through the probe in `plans/landscape.md`
# Appendix A, plus a page served over HTTP, cookies, a screenshot and input.
private class Probe
  @context_id = ""
  @session = ""
  @frame_id = ""
  # The page's main-world execution context, from the latest
  # `Runtime.executionContextCreated` event.
  @execution_context_id = ""

  def initialize(@connection : Crystalfaux::Juggler::Connection, @relay : RecordingRelay)
  end

  def run(page_url : String) : Nil
    open_page
    evaluate_scripts
    load_over_http(page_url)
    capture_and_click
    close_page
  end

  private def open_page : Nil
    call(Protocol::Browser::Enable.new(false, [] of Protocol::Browser::UserPreference))
    call(Protocol::Browser::GetInfo.new).version.should start_with("Firefox/")
    @context_id = call(Protocol::Browser::CreateBrowserContext.new(true)).browser_context_id
    call(Protocol::Browser::NewPage.new(@context_id))
    @session = event(Protocol::Browser::AttachedToTarget, nil).session_id
    @frame_id = event(Protocol::Page::FrameAttached).frame_id
  end

  private def evaluate_scripts : Nil
    load("data:text/html,<!DOCTYPE html><title>crystalfaux</title>")
    title = call(Protocol::Runtime::Evaluate.new(@execution_context_id, "[document.title, navigator.webdriver].join(' | ')", true))
    title.result.try(&.value).should eq(JSON::Any.new("crystalfaux | false"))
    # `null` has an explicit null value; `undefined` has no value at all.
    evaluate_value("null").should eq(JSON::Any.new(nil))
    evaluate_value("undefined").should be_nil
    call(Protocol::Runtime::Evaluate.new(@execution_context_id, "throw new Error('boom')", true))
      .exception_details.should_not be_nil
    # A thrown non-Error arrives as `exceptionDetails.value`. (`throw null`
    # comes back as an `undefined` result, so it cannot be recorded.)
    call(Protocol::Runtime::Evaluate.new(@execution_context_id, "throw 42", true))
      .exception_details.try(&.value).should eq(JSON::Any.new(42_i64))
    arguments = [1_i64, 2_i64].map { |value| Protocol::Runtime::CallFunctionArgument.new(value: JSON::Any.new(value)) }
    sum = call(Protocol::Runtime::CallFunction.new(@execution_context_id, "(a, b) => a + b", arguments, true))
    sum.result.try(&.value).should eq(JSON::Any.new(3_i64))
    null_argument = [Protocol::Runtime::CallFunctionArgument.new(value: JSON::Any.new(nil))]
    kind = call(Protocol::Runtime::CallFunction.new(@execution_context_id, "(a) => a === null", null_argument, true))
    kind.result.try(&.value).should eq(JSON::Any.new(true))
  end

  # Opens a page with a button below the fold and uses the element
  # methods on it: handles by `Runtime.callFunction`, a list of handles by
  # `Runtime.getObjectProperties`, `Page.scrollIntoViewIfNeeded`,
  # `Page.getContentQuads` and `Runtime.disposeObject`.
  def run_elements : Nil
    open_page
    load("data:text/html,<!DOCTYPE html><div style='height:2000px'></div><button>Buy</button>")
    selector = [Protocol::Runtime::CallFunctionArgument.new(value: JSON::Any.new("button"))]
    list = call(Protocol::Runtime::CallFunction.new(@execution_context_id,
      "selector => Array.from(document.querySelectorAll(selector))", selector, false)).result
    list_id = list.try(&.object_id).should_not(be_nil)
    properties = call(Protocol::Runtime::GetObjectProperties.new(@execution_context_id, list_id)).properties
    call(Protocol::Runtime::DisposeObject.new(@execution_context_id, list_id))
    button_id = properties.first.value.object_id.should_not(be_nil)
    call(Protocol::Page::ScrollIntoViewIfNeeded.new(@frame_id, button_id))
    call(Protocol::Page::GetContentQuads.new(@frame_id, button_id)).quads.size.should eq(1)
    call(Protocol::Runtime::DisposeObject.new(@execution_context_id, button_id))
    close_page
  end

  private def evaluate_value(expression : String) : JSON::Any?
    result = call(Protocol::Runtime::Evaluate.new(@execution_context_id, expression, true)).result
    result.should_not be_nil
    result.try(&.value)
  end

  private def load_over_http(page_url : String) : Nil
    navigation_id = call(Protocol::Page::Navigate.new(@frame_id, page_url)).navigation_id
    request_id = event(Protocol::Network::RequestWillBeSent) { |sent| sent.url == page_url }.request_id
    event(Protocol::Network::RequestFinished) { |finished| finished.request_id == request_id }
    wait_for_load(navigation_id)
    body = call(Protocol::Network::GetResponseBody.new(request_id))
    Base64.decode_string(body.base64body).should contain("crystalfaux")
    call(Protocol::Browser::GetCookies.new(@context_id)).cookies.map(&.name).should contain("probe")
  end

  private def capture_and_click : Nil
    call(Protocol::Page::SetViewportSize.new(Protocol::Page::Size.new(640, 480)))
    call(Protocol::Page::Screenshot.new(:png, Protocol::Page::Clip.new(0, 0, 2, 2)))
    call(Protocol::Page::DispatchMouseEvent.new(:mousemove, 10, 10))
  end

  private def close_page : Nil
    call(Protocol::Page::Close.new)
    event(Protocol::Browser::DetachedFromTarget, nil)
    call(Protocol::Browser::RemoveBrowserContext.new(@context_id))
  end

  # Sends a page request to the page session and a browser request to the
  # root session.
  private def call(request : Protocol::Request(R)) : R forall R
    session = request.method_name.starts_with?("Browser.") ? nil : @session
    Protocol.call(@connection, request, session)
  end

  # Navigates and waits for this navigation's `load`. The new page's first
  # `about:blank` load can arrive after `Page.navigate`, so the `load` that
  # counts is the first one after this navigation commits.
  private def load(url : String) : Nil
    wait_for_load(call(Protocol::Page::Navigate.new(@frame_id, url)).navigation_id)
  end

  private def wait_for_load(navigation_id : String?) : Nil
    event(Protocol::Page::NavigationCommitted) { |committed| committed.navigation_id == navigation_id }
    event(Protocol::Page::EventFired, &.name.load?)
  end

  # Waits for the next event of *type* from *session* (the page session by
  # default) that matches the block.
  private def event(type : T.class, session : String? = @session, & : T -> Bool) : T forall T
    params = @relay.wait_for do |message|
      observe(message)
      next false unless message["method"]? == T::METHOD && message["sessionId"]?.try(&.as_s) == session
      yield Protocol.decode(type, message["params"])
    end["params"]
    Protocol.decode(type, params)
  end

  private def event(type : T.class, session : String? = @session) : T forall T
    event(type, session) { true }
  end

  private def observe(message : JSON::Any) : Nil
    return unless message["method"]? == Protocol::Runtime::ExecutionContextCreated::METHOD
    created = Protocol.decode(Protocol::Runtime::ExecutionContextCreated, message["params"])
    @execution_context_id = created.execution_context_id if created.aux_data.name.presence.nil?
  end
end

# Records the fixtures that the offline protocol specs read. To record them
# again:
#
# ```sh
# CRYSTALFAUX_CAMOUFOX=/path/to/camoufox CRYSTALFAUX_RECORD_FIXTURES=1 \
#   crystal spec spec/crystalfaux/protocol/recording_spec.cr --tag browser
# ```
describe "Juggler fixture recording", tags: "browser" do
  it "drives Camoufox through the probe and every frame round-trips through the typed structs" do
    binary = camoufox_binary
    server, page_url = start_page_server
    browser = Crystalfaux::Launcher::BrowserProcess.launch(Crystalfaux::Launcher::Options.new(executable: binary))
    relay = RecordingRelay.new(browser.transport)
    connection = Crystalfaux::Juggler::Connection.new(relay.transport)

    Probe.new(connection, relay).run(page_url)
    # Send Browser.close first and wait until it reaches the browser, so the
    # recording has it; then close the pipe, as `BrowserProcess#close` does.
    connection.notify(Protocol::Browser::Close::METHOD, Protocol::Browser::Close.new)
    relay.wait_until_sent(Protocol::Browser::Close::METHOD)
    browser.close

    frames = relay.frames
    round_trip = JugglerRoundTrip.new(frames)
    round_trip.failures.should be_empty
    if ENV["CRYSTALFAUX_RECORD_FIXTURES"]?
      Dir.mkdir_p(File.dirname(FIXTURE))
      File.write(FIXTURE, frames.join('\n') + '\n')
    end
  ensure
    connection.try &.close
    browser.try &.close
    server.try &.close
  end

  it "records the element methods and every frame round-trips through the typed structs" do
    binary = camoufox_binary
    browser = Crystalfaux::Launcher::BrowserProcess.launch(Crystalfaux::Launcher::Options.new(executable: binary))
    relay = RecordingRelay.new(browser.transport)
    connection = Crystalfaux::Juggler::Connection.new(relay.transport)

    Probe.new(connection, relay).run_elements

    frames = relay.frames
    JugglerRoundTrip.new(frames).failures.should be_empty
    File.write(ELEMENTS_FIXTURE, frames.join('\n') + '\n') if ENV["CRYSTALFAUX_RECORD_FIXTURES"]?
  ensure
    connection.try &.close
    browser.try &.close
  end
end
