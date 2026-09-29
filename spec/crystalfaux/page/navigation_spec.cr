require "../../spec_helper"

# Hand-written event sequences for `Page#goto`, in the order Camoufox
# 152.0.4-beta.31 sends them for an HTTP navigation: the reply to
# `Page.navigate`, the document request with the navigation's id, its
# response, then `Page.navigationCommitted` or `Page.navigationAborted`,
# then the lifecycle events of the new document.
private module NavigationScript
  NAVIGATION_ID = "nav-21"
  URL           = "http://127.0.0.1:8080/page"

  def self.event(method : String, params) : JSON::Any
    json_frame({method: method, params: params, sessionId: ProbeScript::SESSION_ID})
  end

  def self.reply(navigation_id : String? = NAVIGATION_ID) : JSON::Any
    json_frame({id: 0, result: {navigationId: navigation_id}})
  end

  def self.request(request_id : String, url : String = URL, navigation_id : String? = NAVIGATION_ID,
                   redirected_from : String? = nil, frame_id : String = ProbeScript::FRAME_ID) : JSON::Any
    cause = navigation_id ? "TYPE_DOCUMENT" : "TYPE_IMAGE"
    event("Network.requestWillBeSent", {
      url: url, frameId: frame_id, isIntercepted: false, requestId: request_id, redirectedFrom: redirected_from,
      method: "GET", navigationId: navigation_id, cause: cause, internalCause: cause, headers: [] of String,
    })
  end

  def self.response(request_id : String, status : Int32, status_text : String) : JSON::Any
    event("Network.responseReceived", {
      requestId: request_id, fromCache: false, status: status, statusText: status_text,
      headers: [] of String, timing: {startTime: 0, domainLookupStart: 0, domainLookupEnd: 0, connectStart: 0, secureConnectionStart: 0, connectEnd: 0, requestStart: 0, responseStart: 0}, fromServiceWorker: false, securityDetails: nil,
    })
  end

  def self.finished(request_id : String) : JSON::Any
    event("Network.requestFinished", {requestId: request_id})
  end

  def self.started(navigation_id : String = NAVIGATION_ID) : JSON::Any
    event("Page.navigationStarted", {frameId: ProbeScript::FRAME_ID, navigationId: navigation_id})
  end

  def self.committed(url : String = URL, navigation_id : String = NAVIGATION_ID) : JSON::Any
    event("Page.navigationCommitted", {frameId: ProbeScript::FRAME_ID, navigationId: navigation_id, url: url, name: ""})
  end

  def self.aborted(error_text : String) : JSON::Any
    event("Page.navigationAborted", {frameId: ProbeScript::FRAME_ID, navigationId: NAVIGATION_ID, errorText: error_text})
  end

  def self.fired(name : String) : JSON::Any
    event("Page.eventFired", {frameId: ProbeScript::FRAME_ID, name: name})
  end

  # A navigation to `URL` that answers *status* and loads.
  def self.load(status : Int32 = 200, status_text : String = "OK") : Array(JSON::Any)
    [reply, request("10"), started, response("10", status, status_text), finished("10"),
     committed, fired("DOMContentLoaded"), fired("load")]
  end
end

private def goto_page(& : Crystalfaux::Page, ScriptedBrowser ->) : Nil
  browser, fake = scripted_browser
  begin
    yield browser.new_context.new_page, fake
  ensure
    browser.close
    fake.close
  end
end

describe Crystalfaux::Page do
  describe "#goto" do
    it "returns the response of the main-frame document" do
      goto_page do |page, fake|
        fake.on("Page.navigate") { NavigationScript.load }

        response = page.goto(NavigationScript::URL, timeout: 1.second).should_not(be_nil)

        response.status.should eq(200)
        response.url.should eq(NavigationScript::URL)
        response.request.navigation?.should be_true
      end
    end

    it "returns the final response after a redirect" do
      goto_page do |page, fake|
        final_url = "http://127.0.0.1:8080/final"
        fake.on("Page.navigate") do
          [NavigationScript.reply, NavigationScript.request("10"), NavigationScript.started,
           NavigationScript.response("10", 302, "Found"), NavigationScript.finished("10"),
           NavigationScript.request("11-redirect1", final_url, redirected_from: "10"),
           NavigationScript.response("11-redirect1", 200, "OK"), NavigationScript.finished("11-redirect1"),
           NavigationScript.committed(final_url), NavigationScript.fired("DOMContentLoaded"), NavigationScript.fired("load")]
        end

        response = page.goto(NavigationScript::URL, timeout: 1.second).should_not(be_nil)

        response.status.should eq(200)
        response.url.should eq(final_url)
      end
    end

    it "matches the response by navigation id, not by URL" do
      goto_page do |page, fake|
        fake.on("Page.navigate") do
          events = NavigationScript.load
          # A subresource and another navigation's document request with the
          # same URL, answered before the navigation's own response.
          others = [NavigationScript.request("8", navigation_id: nil), NavigationScript.response("8", 500, "Server Error"),
                    NavigationScript.request("9", navigation_id: "nav-7"), NavigationScript.response("9", 503, "Unavailable")]
          events[0, 3] + others + events[3..]
        end

        response = page.goto(NavigationScript::URL, timeout: 1.second).should_not(be_nil)

        response.status.should eq(200)
        response.request.id.should eq("10")
      end
    end

    it "returns nil for a navigation without a network response" do
      goto_page do |page, fake|
        fake.on("Page.navigate") do
          [NavigationScript.reply, NavigationScript.started, NavigationScript.committed("about:blank"),
           NavigationScript.fired("DOMContentLoaded"), NavigationScript.fired("load")]
        end

        page.goto("about:blank", timeout: 1.second).should be_nil
      end
    end

    it "returns nil for a navigation within the document" do
      goto_page do |page, fake|
        fake.on("Page.navigate") { [NavigationScript.reply(nil)] }

        page.goto("about:blank#top", timeout: 100.milliseconds).should be_nil
      end
    end

    it "raises NavigationError with the response when an empty error response aborts the navigation" do
      goto_page do |page, fake|
        fake.on("Page.navigate") do
          [NavigationScript.reply, NavigationScript.request("10"), NavigationScript.started,
           NavigationScript.response("10", 404, "Not Found"),
           NavigationScript.event("Network.requestFailed", {requestId: "10", errorCode: "NS_ERROR_NET_EMPTY_RESPONSE"}),
           NavigationScript.aborted("NS_ERROR_NET_EMPTY_RESPONSE")]
        end

        error = expect_raises(Crystalfaux::NavigationError, /NS_ERROR_NET_EMPTY_RESPONSE/) do
          page.goto(NavigationScript::URL, timeout: 1.second)
        end

        response = error.response.should_not(be_nil)
        response.status.should eq(404)
        response.url.should eq(NavigationScript::URL)
      end
    end

    it "raises NavigationError without a response when the navigation aborts before one" do
      goto_page do |page, fake|
        fake.on("Page.navigate") do
          [NavigationScript.reply, NavigationScript.request("10"), NavigationScript.started,
           NavigationScript.aborted("NS_ERROR_CONNECTION_REFUSED")]
        end

        error = expect_raises(Crystalfaux::NavigationError, /NS_ERROR_CONNECTION_REFUSED/) do
          page.goto(NavigationScript::URL, timeout: 1.second)
        end

        error.response.should be_nil
      end
    end

    it "waits for load by default, not for DOMContentLoaded" do
      goto_page do |page, fake|
        fake.on("Page.navigate") { NavigationScript.load[0..-2] }

        expect_raises(Crystalfaux::TimeoutError) do
          page.goto(NavigationScript::URL, timeout: 200.milliseconds)
        end
      end
    end

    it "returns after DOMContentLoaded with wait_until: :dom_content_loaded" do
      goto_page do |page, fake|
        fake.on("Page.navigate") { NavigationScript.load[0..-2] }

        response = page.goto(NavigationScript::URL, timeout: 1.second, wait_until: :dom_content_loaded).should_not(be_nil)

        response.status.should eq(200)
      end
    end

    it "does not take the DOMContentLoaded of the previous document for its own" do
      goto_page do |page, fake|
        # Camoufox can send the previous document's lifecycle events after
        # `Page.navigate`; the new document never commits here.
        fake.on("Page.navigate") { [NavigationScript.fired("DOMContentLoaded")] + NavigationScript.load[0, 5] }

        expect_raises(Crystalfaux::TimeoutError) do
          page.goto(NavigationScript::URL, timeout: 200.milliseconds, wait_until: :dom_content_loaded)
        end
      end
    end

    it "returns at the commit with wait_until: :commit" do
      goto_page do |page, fake|
        fake.on("Page.navigate") { NavigationScript.load[0..-3] }

        response = page.goto(NavigationScript::URL, timeout: 1.second, wait_until: :commit).should_not(be_nil)

        response.status.should eq(200)
        page.url.should eq(NavigationScript::URL)
      end
    end
  end
end
