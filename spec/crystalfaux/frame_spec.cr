require "../spec_helper"

private CHILD_ID      = "child-1"
private CHILD_CONTEXT = "id-7"

private def reply(result) : Array(JSON::Any)
  [json_frame({id: 0, result: result})]
end

private def error_reply(message : String) : Array(JSON::Any)
  [json_frame({id: 0, error: {message: message}})]
end

private def context_created(fake : ScriptedBrowser, context_id : String, frame_id : String, name : String = "") : Nil
  fake.event("Runtime.executionContextCreated", {executionContextId: context_id, auxData: {frameId: frame_id, name: name}})
end

# A loaded page with one child frame whose default world is `CHILD_CONTEXT`.
private def page_with_child(browser : Crystalfaux::Browser, fake : ScriptedBrowser) : {Crystalfaux::Page, Crystalfaux::Frame}
  page = loaded_page(browser)
  fake.event("Page.frameAttached", {frameId: CHILD_ID, parentFrameId: ProbeScript::FRAME_ID})
  context_created(fake, CHILD_CONTEXT, CHILD_ID)
  page.wait_for_events_for_spec
  {page, page.main_frame.children.first}
end

describe Crystalfaux::Frame do
  describe "execution contexts" do
    it "tracks the default world of each frame and ignores other worlds" do
      browser, fake = scripted_browser
      page, child = page_with_child(browser, fake)
      context_created(fake, "id-9", ProbeScript::FRAME_ID, "__playwright_utility_world__")
      page.wait_for_events_for_spec

      page.main_frame.default_context_id.should eq("id-3")
      child.default_context_id.should eq(CHILD_CONTEXT)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "forgets a context when the browser destroys it" do
      browser, fake = scripted_browser
      page, child = page_with_child(browser, fake)

      fake.event("Runtime.executionContextDestroyed", {executionContextId: CHILD_CONTEXT})
      page.wait_for_events_for_spec

      child.default_context_id.should be_nil
      page.main_frame.default_context_id.should eq("id-3")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "forgets every context when the browser clears them" do
      browser, fake = scripted_browser
      page, child = page_with_child(browser, fake)

      fake.event("Runtime.executionContextsCleared", nil)
      page.wait_for_events_for_spec

      child.default_context_id.should be_nil
      page.main_frame.default_context_id.should be_nil
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "keeps the context of the new document after a navigation" do
      browser, fake = scripted_browser
      page = loaded_page(browser)

      # The order Camoufox sends for a navigation: the old document's
      # context goes, the new one comes, then the commit.
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      context_created(fake, "id-11", ProbeScript::FRAME_ID)
      fake.event("Page.navigationCommitted", {frameId: ProbeScript::FRAME_ID, navigationId: "nav-9", url: "about:blank", name: ""})
      page.wait_for_events_for_spec

      page.main_frame.default_context_id.should eq("id-11")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "forgets the contexts of a detached frame and its descendants" do
      browser, fake = scripted_browser
      page, child = page_with_child(browser, fake)
      fake.event("Page.frameAttached", {frameId: "grandchild-1", parentFrameId: CHILD_ID})
      context_created(fake, "id-8", "grandchild-1")
      page.wait_for_events_for_spec
      grandchild = child.children.first

      fake.event("Page.frameDetached", {frameId: CHILD_ID})
      page.wait_for_events_for_spec

      child.default_context_id.should be_nil
      grandchild.default_context_id.should be_nil
      expect_raises(Crystalfaux::ExecutionContextDestroyed) { grandchild.evaluate("1") }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#evaluate" do
    it "evaluates in the frame's own execution context" do
      browser, fake = scripted_browser
      _, child = page_with_child(browser, fake)
      fake.on("Runtime.evaluate") { reply({result: {value: "child"}}) }

      child.evaluate("document.body.textContent").should eq(JSON::Any.new("child"))

      request = fake.request("Runtime.evaluate")
      request["params"]["executionContextId"].should eq(CHILD_CONTEXT)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "evaluates in the main world through the frame's default context" do
      browser, fake = scripted_browser
      _, child = page_with_child(browser, fake)
      fake.on("Runtime.callFunction") { reply({result: {value: {o: [{k: "marker", v: 7}], id: 1}}}) }

      child.evaluate("({marker: window.childMarker})", world: :main).should eq(JSON.parse(%({"marker":7})))

      params = fake.request("Runtime.callFunction")["params"]
      params["executionContextId"].should eq(CHILD_CONTEXT)
      params["args"][3]["value"].should eq("mw:({marker: window.childMarker})")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises EvaluationError when main-world evaluation is not allowed" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      disabled = "Main world evaluation is disabled. Launch with main_world_eval=True to use the \"mw:\" prefix."
      fake.on("Runtime.callFunction") { reply({exceptionDetails: {text: disabled}}) }

      expect_raises(Crystalfaux::EvaluationError, /disabled/) { page.evaluate("window.marker", world: :main) }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ExecutionContextDestroyed when the frame has no context" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec

      expect_raises(Crystalfaux::ExecutionContextDestroyed, /mainframe-10/) { page.evaluate("1") }
      fake.methods.should_not contain("Runtime.evaluate")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ExecutionContextDestroyed, not a timeout, when the context goes during the call" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { [] of JSON::Any }
      outcome = async { page.evaluate("new Promise(() => {})", timeout: 5.seconds) }
      fake.request("Runtime.evaluate")

      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::ExecutionContextDestroyed)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ExecutionContextDestroyed when the frame detaches during the call" do
      browser, fake = scripted_browser
      _, child = page_with_child(browser, fake)
      fake.on("Runtime.evaluate") { [] of JSON::Any }
      outcome = async { child.evaluate("new Promise(() => {})", timeout: 5.seconds) }
      fake.request("Runtime.evaluate")

      fake.event("Page.frameDetached", {frameId: CHILD_ID})

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::ExecutionContextDestroyed)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ExecutionContextDestroyed when the browser reports the context destroyed" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      # What Runtime.js replies when a navigation rejects a pending promise.
      fake.on("Runtime.evaluate") do
        error_reply(%(error in channel "content::10/11/4": exception while running method "evaluate" in namespace "page": Execution context was destroyed!))
      end

      expect_raises(Crystalfaux::ExecutionContextDestroyed) { page.evaluate("new Promise(() => {})") }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises EvaluationError when the result is not serializable" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { error_reply("BigInt value can't be serialized in JSON") }

      expect_raises(Crystalfaux::EvaluationError, /serializ/) { page.evaluate("10n") }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "still fails with PageCrashed when the page crashes during the call" do
      browser, fake = scripted_browser
      _, child = page_with_child(browser, fake)
      fake.on("Runtime.evaluate") { [] of JSON::Any }
      outcome = async { child.evaluate("1", timeout: 5.seconds) }
      fake.request("Runtime.evaluate")

      fake.event("Page.crashed", nil)

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageCrashed)
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
