require "../spec_helper"

private def request_event(request_id : String, url : String, *, intercepted : Bool = true,
                          cause : String = "TYPE_DOCUMENT", method : String = "GET")
  {
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

private def response_event(request_id : String, status : Int32 = 200)
  zero = 0.0
  {
    securityDetails: nil, requestId: request_id, fromCache: false, status: status, statusText: "OK",
    headers: [{name: "Content-Type", value: "text/plain"}], fromServiceWorker: false,
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

    it "fails a body wait with PageClosed when the page closes" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      responses = Channel(Crystalfaux::Response).new(1)
      page.on_response { |response| responses.send(response) }
      fake.event("Network.requestWillBeSent", request_event("r1", "http://example.test/a", intercepted: false))
      fake.event("Network.responseReceived", response_event("r1"))
      response = receive_within(responses)
      body = async { response.body(timeout: 5.seconds); JSON::Any.new(nil) }

      page.close

      receive_within(body).should be_a(Crystalfaux::PageClosed)
    ensure
      browser.try &.close
      fake.try &.close
    end

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
