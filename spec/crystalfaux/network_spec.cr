require "../spec_helper"

private def request_event(request_id : String, url : String, *, intercepted : Bool = true,
                          cause : String = "TYPE_DOCUMENT", method : String = "GET", post_data : String? = nil)
  {
    postData:      post_data,
    frameId:       ProbeScript::FRAME_ID,
    requestId:     request_id,
    headers:       [{name: "Accept", value: "*/*"}],
    isIntercepted: intercepted,
    url:           url,
    method:        method,
    cause:         cause,
    internalCause: cause,
  }
end

private def response_event(request_id : String, status : Int32 = 200,
                           headers = [{name: "Content-Type", value: "text/plain"}])
  zero = 0.0
  {
    securityDetails: nil, requestId: request_id, fromCache: false, status: status, statusText: "OK",
    headers: headers, fromServiceWorker: false,
    timing: {startTime: zero, domainLookupStart: zero, domainLookupEnd: zero, connectStart: zero,
             secureConnectionStart: zero, connectEnd: zero, requestStart: zero, responseStart: zero},
  }
end

private def finished_event(request_id : String)
  {requestId: request_id, responseEndTime: 0.0, transferSize: 5, encodedBodySize: 5}
end

private def intercepting_page(&handler : Crystalfaux::Request ->) : {Crystalfaux::Browser, ScriptedBrowser, Crystalfaux::Page}
  browser, fake = scripted_browser
  page = browser.new_context.new_page
  page.on_request(&handler)
  {browser, fake, page}
end

private def params_of(request : JSON::Any) : JSON::Any
  request["params"]
end

# Ends the page of *fake* one way, as the browser or the caller would.
private def tear_down(how : String, page : Crystalfaux::Page, fake : ScriptedBrowser) : Nil
  case how
  when "closes"  then page.close
  when "crashes" then fake.event("Page.crashed", nil)
  else                fake.close
  end
end

private TEARDOWNS = {
  "closes"      => Crystalfaux::PageClosed,
  "crashes"     => Crystalfaux::PageCrashed,
  "disconnects" => Crystalfaux::ConnectionClosed,
}

describe "network" do
  describe "Page#on_request" do
    it "enables interception for the page and passes each intercepted request to the handler" do
      seen = Channel(Crystalfaux::Request).new(1)
      browser, fake, _ = intercepting_page do |request|
        seen.send(request)
        request.abort
      end

      interception = fake.request("Network.setRequestInterception")
      interception["sessionId"].should eq(ProbeScript::SESSION_ID)
      params_of(interception).should eq(JSON.parse(%({"enabled":true})))

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a.png", cause: "TYPE_IMAGE", method: "POST"))

      request = receive_within(seen)
      request.id.should eq("r1")
      request.url.should eq("http://example.test/a.png")
      request.method.should eq("POST")
      request.headers["Accept"].should eq("*/*")
      request.resource_type.should eq(Crystalfaux::ResourceType::Image)
      request.frame_id.should eq(ProbeScript::FRAME_ID)
      abort = fake.request("Network.abortInterceptedRequest")
      abort["sessionId"].should eq(ProbeScript::SESSION_ID)
      params_of(abort).should eq(JSON.parse(%({"requestId":"r1","errorCode":"failed"})))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "decodes the POST data of a request and encodes a replacement" do
      bodies = Channel(Bytes?).new(3)
      browser, fake, _ = intercepting_page do |request|
        bodies.send(request.post_data)
        request.continue(post_data: "YWJj") if request.id == "r1"
      end
      binary = Bytes[0xc3, 0xa9, 0x00, 0xff]

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/", method: "POST",
        post_data: Base64.strict_encode(binary)))
      fake.event("Network.requestWillBeSent", request_event("r2", "http://example.test/", method: "POST", post_data: ""))
      fake.event("Network.requestWillBeSent", request_event("r3", "http://example.test/"))

      receive_within(bodies).should eq(binary)
      params_of(fake.request("Network.resumeInterceptedRequest")).should eq(
        JSON.parse(%({"requestId":"r1","postData":"#{Base64.strict_encode("YWJj")}"})))
      receive_within(bodies).should eq(Bytes.empty)
      receive_within(bodies).should be_nil
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "retries turning on interception after the first attempt failed" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      attempts = 0
      fake.on("Network.setRequestInterception") do
        attempts += 1
        next [json_frame({id: 0, result: {} of String => String})] if attempts > 1
        [json_frame({id: 0, error: {message: "not now", data: ""}})]
      end
      seen = Channel(String).new(2)

      expect_raises(Crystalfaux::ProtocolError, /not now/) { page.on_request { |request| seen.send("first #{request.id}") } }
      page.on_request do |request|
        seen.send("second #{request.id}")
        request.abort
      end
      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/"))

      receive_within(seen).should eq("second r1")
      fake.request("Network.abortInterceptedRequest")
      fake.methods.count("Network.setRequestInterception").should eq(2)
      quiet?(seen).should be_true
    ensure
      browser.try &.close
      fake.try &.close
    end

    {% for how, error in TEARDOWNS %}
      it "fails the decision of a paused handler with #{{{ error }}} when the page {{ how.id }}" do
        release = Channel(Nil).new
        outcome = Channel(Exception?).new(1)
        browser, fake, page = intercepting_page do |request|
          release.receive
          begin
            request.abort
            outcome.send(nil)
          rescue ex
            outcome.send(ex)
            raise ex
          end
        end
        fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/"))
        page.wait_for_events_for_spec

        tear_down({{ how }}, page, fake)
        page.wait_for_events_for_spec rescue Crystalfaux::ConnectionClosed
        release.send(nil)

        receive_within(outcome).should be_a({{ error }})
        sleep 20.milliseconds # let the page's own fallback decision run, if any
        fake.methods.should_not contain("Network.abortInterceptedRequest")
        fake.methods.should_not contain("Network.resumeInterceptedRequest")
      ensure
        browser.try &.close
        fake.try &.close
      end
    {% end %}

    it "fulfills a request with a status, headers and a base64 body" do
      browser, fake, _ = intercepting_page do |request|
        request.fulfill(status: 201, body: "hello", content_type: "text/plain")
      end

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/"))

      params = params_of(fake.request("Network.fulfillInterceptedRequest"))
      params["requestId"].should eq("r1")
      params["status"].should eq(201)
      params["statusText"].should eq("Created")
      params["base64body"].should eq(Base64.strict_encode("hello"))
      params["headers"].as_a.map { |header| {header["name"].as_s, header["value"].as_s} }
        .should eq([{"Content-Type", "text/plain"}, {"Content-Length", "5"}])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "continues a request with overrides" do
      browser, fake, _ = intercepting_page do |request|
        request.continue(url: "http://example.test/b", headers: HTTP::Headers{"X-Test" => "1"})
      end

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a"))

      params_of(fake.request("Network.resumeInterceptedRequest")).should eq(
        JSON.parse(%({"requestId":"r1","url":"http://example.test/b","headers":[{"name":"X-Test","value":"1"}]})))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "continues a request that no handler decides, even when a handler raises" do
      calls = Channel(String).new(2)
      browser, fake, page = intercepting_page { |request| calls.send("first #{request.id}") }
      page.on_request do |request|
        calls.send("second #{request.id}")
        raise "handler bug"
      end

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/"))

      receive_within(calls).should eq("first r1")
      receive_within(calls).should eq("second r1")
      params_of(fake.request("Network.resumeInterceptedRequest")).should eq(JSON.parse(%({"requestId":"r1"})))
      fake.methods.count("Network.setRequestInterception").should eq(1)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "stops at the first handler that decides, and rejects a second decision" do
      outcome = Channel(Exception?).new(1)
      browser, fake, page = intercepting_page do |request|
        request.abort("blockedbyclient")
        begin
          request.continue
          outcome.send(nil)
        rescue ex
          outcome.send(ex)
        end
      end
      page.on_request { raise "not called" }

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/"))

      receive_within(outcome).should be_a(Crystalfaux::Error)
      fake.request("Network.abortInterceptedRequest")
      page.wait_for_events_for_spec
      fake.methods.should_not contain("Network.resumeInterceptedRequest")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "does not pass requests that the browser did not intercept" do
      seen = Channel(Crystalfaux::Request).new(1)
      browser, fake, page = intercepting_page { |request| seen.send(request) }

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/", intercepted: false))
      page.wait_for_events_for_spec

      quiet?(seen).should be_true
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "Page#on_response and Response#body" do
    it "passes each response to the handler and reads its body after the request finishes" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      responses = Channel(Crystalfaux::Response).new(1)
      page.on_response { |response| responses.send(response) }
      fake.on("Network.getResponseBody") do |request|
        [json_frame({id: 0, result: {base64body: Base64.strict_encode("hello #{request["params"]["requestId"]}")}})]
      end

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a", intercepted: false))
      fake.event("Network.responseReceived", response_event("r1", 404))
      response = receive_within(responses)

      response.url.should eq("http://example.test/a")
      response.status.should eq(404)
      response.headers["Content-Type"].should eq("text/plain")
      response.request.method.should eq("GET")
      body = async { JSON::Any.new(String.new(response.body)) }
      quiet?(body).should be_true
      fake.methods.should_not contain("Network.getResponseBody")

      fake.event("Network.requestFinished", finished_event("r1"))

      receive_within(body).should eq(JSON::Any.new("hello r1"))
      fake.request("Network.getResponseBody")["sessionId"].should eq(ProbeScript::SESSION_ID)
      response.text.should eq("hello r1")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "passes a response whose repeated Set-Cookie values Juggler joined with a newline" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      responses = Channel(Crystalfaux::Response).new(1)
      page.on_response { |response| responses.send(response) }

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a", intercepted: false))
      fake.event("Network.responseReceived",
        response_event("r1", headers: [{name: "Set-Cookie", value: "a=1; Path=/\nb=2; Path=/"}]))
      response = receive_within(responses)

      response.headers.get("Set-Cookie").should eq(["a=1; Path=/", "b=2; Path=/"])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises when the request failed, or the browser evicted the body" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      responses = Channel(Crystalfaux::Response).new(2)
      page.on_response { |response| responses.send(response) }
      fake.on("Network.getResponseBody") { [json_frame({id: 0, result: {base64body: "", evicted: true}})] }

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a", intercepted: false))
      fake.event("Network.responseReceived", response_event("r1"))
      fake.event("Network.requestFailed", {requestId: "r1", errorCode: "NS_BINDING_ABORTED"})
      fake.event("Network.requestWillBeSent", request_event("r2", "http://example.test/b", intercepted: false))
      fake.event("Network.responseReceived", response_event("r2"))
      fake.event("Network.requestFinished", finished_event("r2"))

      failed = receive_within(responses)
      expect_raises(Crystalfaux::Error, /NS_BINDING_ABORTED/) { failed.body }
      evicted = receive_within(responses)
      expect_raises(Crystalfaux::Error, /evicted/) { evicted.body }
    ensure
      browser.try &.close
      fake.try &.close
    end

    {% for how, error in TEARDOWNS %}
      it "fails a body wait with #{{{ error }}} when the page {{ how.id }}" do
        browser, fake = scripted_browser
        page = browser.new_context.new_page
        responses = Channel(Crystalfaux::Response).new(1)
        page.on_response { |response| responses.send(response) }
        fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a", intercepted: false))
        fake.event("Network.responseReceived", response_event("r1"))
        response = receive_within(responses)
        body = async { response.body(timeout: 5.seconds); JSON::Any.new(nil) }

        tear_down({{ how }}, page, fake)

        receive_within(body).should be_a({{ error }})
      ensure
        browser.try &.close
        fake.try &.close
      end
    {% end %}

    it "raises TimeoutError when the request does not finish in time" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      responses = Channel(Crystalfaux::Response).new(1)
      page.on_response { |response| responses.send(response) }
      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a", intercepted: false))
      fake.event("Network.responseReceived", response_event("r1"))

      expect_raises(Crystalfaux::TimeoutError) { receive_within(responses).body(timeout: 50.milliseconds) }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "Context#block" do
    it "enables interception for the context once and aborts the matching requests" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page

      context.block(types: [Crystalfaux::ResourceType::Image])
      context.block(urls: ["**/ads/**", /tracker/])

      interception = fake.request("Browser.setRequestInterception")
      interception["sessionId"]?.should be_nil
      params_of(interception).should eq(JSON.parse(%({"browserContextId":"#{ProbeScript::CONTEXT_ID}","enabled":true})))
      fake.methods.count("Browser.setRequestInterception").should eq(1)

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a.png", cause: "TYPE_IMAGE"))
      params_of(fake.request("Network.abortInterceptedRequest")).should eq(JSON.parse(%({"requestId":"r1","errorCode":"blockedbyclient"})))
      fake.event("Network.requestWillBeSent", request_event("r2", "http://example.test/ads/x.js", cause: "TYPE_SCRIPT"))
      params_of(fake.request("Network.abortInterceptedRequest"))["requestId"].should eq("r2")
      fake.event("Network.requestWillBeSent", request_event("r3", "http://tracker.test/", cause: "TYPE_XMLHTTPREQUEST"))
      params_of(fake.request("Network.abortInterceptedRequest"))["requestId"].should eq("r3")
      fake.event("Network.requestWillBeSent", request_event("r4", "http://example.test/", cause: "TYPE_DOCUMENT"))
      params_of(fake.request("Network.resumeInterceptedRequest")).should eq(JSON.parse(%({"requestId":"r4"})))
      page.wait_for_events_for_spec
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "aborts a blocked request before the page's handlers see it" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page
      seen = Channel(String).new(2)
      page.on_request { |request| seen.send(request.id) }
      context.block(types: [Crystalfaux::ResourceType::Image])

      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a.png", cause: "TYPE_IMAGE"))
      fake.event("Network.requestWillBeSent", request_event("r2", "http://example.test/"))

      receive_within(seen).should eq("r2")
      params_of(fake.request("Network.abortInterceptedRequest"))["requestId"].should eq("r1")
      quiet?(seen).should be_true
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "Context headers and cookies" do
    it "sets extra headers for the context" do
      browser, fake = scripted_browser
      context = browser.new_context

      context.extra_headers = HTTP::Headers{"X-Test" => ["1", "2"]}

      params_of(fake.request("Browser.setExtraHTTPHeaders")).should eq(JSON.parse(
        %({"browserContextId":"#{ProbeScript::CONTEXT_ID}","headers":[{"name":"X-Test","value":"1"},{"name":"X-Test","value":"2"}]})))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "sets, reads and clears the cookies of the context" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.getCookies") do
        [json_frame({id: 0, result: {cookies: [{name: "a", domain: "example.test", path: "/", value: "1", expires: -1,
                                                size: 2, httpOnly: false, secure: false, session: true, sameSite: "Lax"}]}})]
      end

      context.set_cookies([Crystalfaux::CookieOptions.new("a", "1", url: "http://example.test/")])
      cookies = context.cookies
      context.clear_cookies

      params_of(fake.request("Browser.setCookies")).should eq(JSON.parse(
        %({"browserContextId":"#{ProbeScript::CONTEXT_ID}","cookies":[{"name":"a","value":"1","url":"http://example.test/"}]})))
      params_of(fake.request("Browser.getCookies")).should eq(JSON.parse(%({"browserContextId":"#{ProbeScript::CONTEXT_ID}"})))
      params_of(fake.request("Browser.clearCookies")).should eq(JSON.parse(%({"browserContextId":"#{ProbeScript::CONTEXT_ID}"})))
      cookies.map { |cookie| {cookie.name, cookie.value, cookie.same_site} }
        .should eq([{"a", "1", Crystalfaux::Protocol::Browser::SameSite::Lax}])
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
