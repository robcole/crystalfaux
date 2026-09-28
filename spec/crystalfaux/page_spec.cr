require "../spec_helper"

private alias Page = Crystalfaux::Page

private def evaluation_reply(result : String) : Array(JSON::Any)
  [JSON.parse(%({"id":0,"result":#{result}}))]
end

describe Crystalfaux::Page do
  describe "#goto" do
    it "navigates the main frame and returns after its load event" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page

      page.goto(ProbeScript::DATA_URL)

      request = fake.request("Page.navigate")
      request["sessionId"].should eq(ProbeScript::SESSION_ID)
      request["params"].should eq(JSON.parse({frameId: ProbeScript::FRAME_ID, url: ProbeScript::DATA_URL}.to_json))
      page.url.should eq(ProbeScript::DATA_URL)
      page.main_frame.url.should eq(ProbeScript::DATA_URL)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "does not take the load of an earlier navigation for its own" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      # The load of the previous document arrives before the reply; the
      # new document never commits.
      earlier_load = JSON.parse({method: "Page.eventFired", params: {frameId: ProbeScript::FRAME_ID, name: "load"}, sessionId: ProbeScript::SESSION_ID}.to_json)
      fake.on("Page.navigate") { [earlier_load, ProbeScript.navigate.first] }

      expect_raises(Crystalfaux::TimeoutError, /navigation/i) do
        page.goto(ProbeScript::DATA_URL, timeout: 100.milliseconds)
      end
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "handles navigation events that arrive before the reply" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      events = ProbeScript.navigate
      fake.on("Page.navigate") { events[1..] + [events.first] }

      page.goto(ProbeScript::DATA_URL, timeout: 1.second)

      page.url.should eq(ProbeScript::DATA_URL)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises NavigationError when the navigation is aborted" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      reply = ProbeScript.navigate.first
      navigation_id = reply["result"]["navigationId"].as_s
      aborted = JSON.parse({method: "Page.navigationAborted", sessionId: ProbeScript::SESSION_ID,
                            params: {frameId: ProbeScript::FRAME_ID, navigationId: navigation_id, errorText: "NS_BINDING_ABORTED"}}.to_json)
      fake.on("Page.navigate") { [reply, aborted] }

      expect_raises(Crystalfaux::NavigationError, /NS_BINDING_ABORTED/) do
        page.goto(ProbeScript::DATA_URL)
      end
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises NavigationError when another navigation commits before the load" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      reply = ProbeScript.navigate.first
      navigation_id = reply["result"]["navigationId"].as_s
      commit = ->(id : String, url : String) do
        json_frame({method: "Page.navigationCommitted", sessionId: ProbeScript::SESSION_ID,
                    params: {frameId: ProbeScript::FRAME_ID, navigationId: id, url: url, name: ""}})
      end
      load = json_frame({method: "Page.eventFired", sessionId: ProbeScript::SESSION_ID,
                         params: {frameId: ProbeScript::FRAME_ID, name: "load"}})
      fake.on("Page.navigate") do
        [reply, commit.call(navigation_id, ProbeScript::DATA_URL), commit.call("nav-99", "about:blank#b"), load]
      end

      expect_raises(Crystalfaux::NavigationError, /replaced/) do
        page.goto(ProbeScript::DATA_URL, timeout: 1.second)
      end
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "returns at once for a navigation within the document" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.navigate") { [JSON.parse(%({"id":0,"result":{"navigationId":null}}))] }

      page.goto("about:blank#top", timeout: 100.milliseconds)
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#evaluate" do
    it "evaluates in the main world of the main frame and returns the value" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { [ProbeScript.reply_to(&.["params"]["expression"]?.==("[document.title, navigator.webdriver].join(' | ')"))] }

      page.evaluate("[document.title, navigator.webdriver].join(' | ')").should eq(JSON::Any.new("crystalfaux | false"))

      request = fake.request("Runtime.evaluate")
      request["sessionId"].should eq(ProbeScript::SESSION_ID)
      # id-3 is the context created for the new document.
      request["params"].should eq(JSON.parse(%({"executionContextId":"id-3","expression":"[document.title, navigator.webdriver].join(' | ')","returnByValue":true})))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "returns JSON null for both null and undefined" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { |request| [ProbeScript.reply_to(&.["params"]["expression"]?.==(request["params"]["expression"]))] }

      page.evaluate("null").should eq(JSON::Any.new(nil))
      page.evaluate("undefined").should eq(JSON::Any.new(nil))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "returns numbers that JSON cannot carry as floats" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { evaluation_reply(%({"result":{"unserializableValue":"-Infinity"}})) }

      page.evaluate("-Infinity").should eq(JSON::Any.new(-Float64::INFINITY))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises EvaluationError when the script throws" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { |request| [ProbeScript.reply_to(&.["params"]["expression"]?.==(request["params"]["expression"]))] }

      error = expect_raises(Crystalfaux::EvaluationError, "boom") { page.evaluate("throw new Error('boom')") }
      error.stack.should eq("@debugger eval code:1:7\n")
      expect_raises(Crystalfaux::EvaluationError, "42") { page.evaluate("throw 42") }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#title and #content" do
    it "read the document of the main frame" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") do |request|
        expression = request["params"]["expression"].as_s
        value = expression == "document.title" ? "crystalfaux" : "<!DOCTYPE html><html><head><title>crystalfaux</title></head><body></body></html>"
        evaluation_reply({result: {value: value}}.to_json)
      end

      page.title.should eq("crystalfaux")
      page.content.should start_with("<!DOCTYPE html><html>")
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "frames" do
    it "tracks child frames and their URLs" do
      browser, fake = scripted_browser
      page = loaded_page(browser)

      fake.event("Page.frameAttached", {frameId: "child-1", parentFrameId: ProbeScript::FRAME_ID})
      fake.event("Page.navigationCommitted", {frameId: "child-1", navigationId: "nav-9", url: "about:srcdoc", name: ""})
      fake.event("Page.sameDocumentNavigation", {frameId: ProbeScript::FRAME_ID, url: "#{ProbeScript::DATA_URL}#top"})
      fake.event("Page.ready", nil)
      page.wait_for_events_for_spec

      child = page.main_frame.children.first
      child.id.should eq("child-1")
      child.url.should eq("about:srcdoc")
      child.parent.should be(page.main_frame)
      page.main_frame.parent.should be_nil
      page.url.should eq("#{ProbeScript::DATA_URL}#top")

      fake.event("Page.frameDetached", {frameId: "child-1"})
      page.wait_for_events_for_spec
      page.main_frame.children.should be_empty
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "forgets the descendants of a detached frame" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Page.frameAttached", {frameId: "child-1", parentFrameId: ProbeScript::FRAME_ID})
      fake.event("Page.frameAttached", {frameId: "grandchild-1", parentFrameId: "child-1"})
      page.wait_for_events_for_spec
      grandchild = page.main_frame.children.first.children.first

      fake.event("Page.frameDetached", {frameId: "child-1"})
      fake.event("Page.navigationCommitted", {frameId: "grandchild-1", navigationId: "nav-9", url: "about:srcdoc", name: ""})
      # A new frame with the old id is a new child, not the old grandchild.
      fake.event("Page.frameAttached", {frameId: "grandchild-1", parentFrameId: ProbeScript::FRAME_ID})
      page.wait_for_events_for_spec

      grandchild.url.should eq("")
      page.main_frame.children.map(&.id).should eq(["grandchild-1"])
      page.main_frame.children.first.should_not be(grandchild)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "tracks the main and utility worlds of each frame separately" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      frame = page.main_frame
      frame.main_context_id.should eq("id-3")
      frame.utility_context_id.should be_nil

      fake.event("Runtime.executionContextCreated", {executionContextId: "id-9", auxData: {frameId: ProbeScript::FRAME_ID, name: Page::UTILITY_WORLD}})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-10", auxData: {frameId: ProbeScript::FRAME_ID, name: "other-extension"}})
      page.wait_for_events_for_spec
      frame.main_context_id.should eq("id-3")
      frame.utility_context_id.should eq("id-9")

      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec
      frame.main_context_id.should be_nil
      frame.utility_context_id.should eq("id-9")

      fake.event("Runtime.executionContextsCleared", nil)
      page.wait_for_events_for_spec
      frame.utility_context_id.should be_nil
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "pending requests" do
    it "fail with PageCrashed when the page crashes before the navigate reply" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.navigate") { [] of JSON::Any }
      outcome = async { page.goto(ProbeScript::DATA_URL, timeout: 5.seconds); JSON::Any.new(nil) }
      fake.request("Page.navigate")

      fake.event("Page.crashed", nil)

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageCrashed)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "fail with PageCrashed when the page crashes before the evaluate reply" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { [] of JSON::Any }
      outcome = async { page.evaluate("1", timeout: 5.seconds) }
      fake.request("Runtime.evaluate")

      fake.event("Page.crashed", nil)

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageCrashed)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "fail with PageClosed when the page closes, and a late reply is ignored" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page
      fake.on("Runtime.evaluate") { [] of JSON::Any }
      outcome = async { page.title(timeout: 5.seconds); JSON::Any.new(nil) }
      request = fake.request("Runtime.evaluate")

      page.close

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageClosed)
      fake.peer.reply(request["id"], {result: {value: "late"}}, ProbeScript::SESSION_ID)
      # The late reply is dropped; the connection and context still work.
      browser.new_context.id.should eq(ProbeScript::CONTEXT_ID)
      browser.closed?.should be_false
      context.closed?.should be_false
      context.pages.should be_empty
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "fail with ConnectionClosed when the pipe closes before the reply" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { [] of JSON::Any }
      outcome = async { page.evaluate("1", timeout: 5.seconds) }
      fake.request("Runtime.evaluate")

      fake.close

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::ConnectionClosed)
    ensure
      browser.try &.close
    end
  end

  describe "when the page crashes" do
    it "fails a navigation in progress and later calls with PageCrashed" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.navigate") { [ProbeScript.navigate.first] }
      outcome = async { page.goto(ProbeScript::DATA_URL); JSON::Any.new(nil) }
      fake.request("Page.navigate")

      fake.event("Page.crashed", nil)

      receive_within(outcome).should be_a(Crystalfaux::PageCrashed)
      page.crashed?.should be_true
      expect_raises(Crystalfaux::PageCrashed) { page.evaluate("1") }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#close" do
    it "closes the page target and forgets the page" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page

      page.close
      page.close

      fake.request("Page.close")["sessionId"].should eq(ProbeScript::SESSION_ID)
      fake.methods.count("Page.close").should eq(1)
      page.closed?.should be_true
      context.pages.should be_empty
      expect_raises(Crystalfaux::PageClosed) { page.goto(ProbeScript::DATA_URL) }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "stops following the page's events after its context closes" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page

      context.close
      fake.event("Page.navigationCommitted", {frameId: ProbeScript::FRAME_ID, navigationId: "nav-9", url: "about:blank#late", name: ""})
      page.wait_for_events_for_spec

      page.url.should eq("about:blank")
      browser.closed?.should be_false
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "closes the page when the browser detaches its target" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page

      fake.event("Browser.detachedFromTarget", {sessionId: ProbeScript::SESSION_ID, targetId: ProbeScript::TARGET_ID}, nil)
      page.wait_for_events_for_spec

      page.closed?.should be_true
      context.pages.should be_empty
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
