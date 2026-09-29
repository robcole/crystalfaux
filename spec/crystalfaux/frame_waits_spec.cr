require "../spec_helper"

private def reply(result) : Array(JSON::Any)
  [json_frame({id: 0, result: result})]
end

private def error_reply(message : String) : Array(JSON::Any)
  [json_frame({id: 0, error: {message: message}})]
end

# Replies to the requests for *method* with *replies* in turn, then with the
# last one.
private def replies_in_turn(fake : ScriptedBrowser, method : String, replies : Array(Array(JSON::Any))) : Nil
  index = 0
  fake.on(method) do
    frames = replies[{index, replies.size - 1}.min]
    index += 1
    frames
  end
end

private DESTROYED = %(error in channel "content::10/11/4": exception while running method "evaluate" in namespace "page": Execution context was destroyed!)

# What a caller's guard raises when it sees a challenge.
private class ChallengeSeen < Exception
end

# A guard that passes once, then raises *error*: the wait polls once.
private def guard_raising(error : Exception) : Crystalfaux::Guard
  calls = 0
  -> do
    calls += 1
    raise error if calls > 1
  end
end

describe Crystalfaux::Frame do
  describe "#wait_for_function" do
    it "polls until the expression is truthy and returns that value" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      replies_in_turn(fake, "Runtime.evaluate", [
        reply({result: {type: "object", subtype: "null", value: nil}}),
        reply({result: {type: "number", value: 0}}),
        reply({result: {type: "string", value: ""}}),
        reply({result: {type: "object", value: {count: 3}}}),
      ])

      value = page.wait_for_function("window.ready", polling: 10.milliseconds)

      value.should eq(json_frame({count: 3}))
      fake.methods.count("Runtime.evaluate").should eq(4)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "keeps waiting through a navigation that destroys the context" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      replies_in_turn(fake, "Runtime.evaluate", [error_reply(DESTROYED), reply({result: {type: "boolean", value: true}})])

      page.wait_for_function("document.readyState == 'complete'", polling: 10.milliseconds).should eq(JSON::Any.new(true))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "keeps waiting while the frame has no context" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { reply({result: {type: "boolean", value: true}}) }
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec

      outcome = async { page.wait_for_function("true", polling: 10.milliseconds) }
      quiet?(outcome, 50.milliseconds).should be_true
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-11", auxData: {frameId: ProbeScript::FRAME_ID, name: ""}})

      receive_within(outcome).should eq(JSON::Any.new(true))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises TimeoutError at the deadline" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { reply({result: {type: "boolean", value: false}}) }

      started = Time.instant
      expect_raises(Crystalfaux::TimeoutError, /window\.ready/) do
        page.wait_for_function("window.ready", timeout: 150.milliseconds, polling: 20.milliseconds)
      end
      (Time.instant - started).should be < 1.second
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises what the script throws" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { reply({exceptionDetails: {text: "ReferenceError: nope is not defined"}}) }

      expect_raises(Crystalfaux::EvaluationError, /nope/) { page.wait_for_function("nope") }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "a page that goes away between documents" do
    it "raises PageClosed from an evaluation, not ExecutionContextDestroyed" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec
      page.close

      expect_raises(Crystalfaux::PageClosed) { page.evaluate("1") }
      expect_raises(Crystalfaux::PageClosed) { page.query_selector("#go") }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "ends a function wait with PageClosed at once" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec
      outcome = async { page.wait_for_function("true", timeout: 5.seconds, polling: 10.milliseconds) }
      quiet?(outcome, 50.milliseconds).should be_true

      page.close

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageClosed)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "ends a selector wait with PageCrashed at once" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec
      outcome = Channel(Crystalfaux::ElementHandle? | Exception).new(1)
      spawn do
        outcome.send(page.wait_for_selector("#go", timeout: 5.seconds))
      rescue ex
        outcome.send(ex)
      end
      quiet?(outcome, 150.milliseconds).should be_true

      fake.event("Page.crashed", nil)

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageCrashed)
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#wait_for_selector" do
    it "returns a handle once the element reaches the state" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      replies_in_turn(fake, "Runtime.callFunction", [
        reply({result: {type: "boolean", value: false}}),
        reply({result: {type: "object", subtype: "node", objectId: "obj-1"}}),
      ])

      handle = page.wait_for_selector(".dialog", state: :visible).should_not(be_nil)

      handle.remote_object_id.should eq("obj-1")
      params = fake.request("Runtime.callFunction")["params"]
      params["returnByValue"].should be_false
      params["args"].should eq(json_frame([{value: ".dialog"}, {value: "visible"}]))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "returns nil for the hidden and detached states" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply({result: {type: "boolean", value: true}}) }

      page.wait_for_selector(".dialog", state: :hidden).should be_nil
      page.wait_for_selector(".dialog", state: :detached).should be_nil
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises TimeoutError naming the selector and state" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply({result: {type: "boolean", value: false}}) }

      expect_raises(Crystalfaux::TimeoutError, /\.dialog.*hidden/) do
        page.wait_for_selector(".dialog", state: :hidden, timeout: 150.milliseconds)
      end
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#get_by_role" do
    it "sends the role, the name and exact, and returns the handles" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply({result: {type: "object", subtype: "array", objectId: "list-1"}}) }
      fake.on("Runtime.getObjectProperties") do
        reply({properties: [{name: "0", value: {type: "object", subtype: "node", objectId: "obj-a"}}]})
      end

      page.get_by_role("button", name: "Add to cart", exact: false).map(&.remote_object_id).should eq(["obj-a"])

      params = fake.request("Runtime.callFunction")["params"]
      params["functionDeclaration"].should eq(Crystalfaux::DomScripts::BY_ROLE)
      params["args"].should eq(json_frame([{value: "button"}, {value: "Add to cart"}, {value: false}]))
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "waits with a guard" do
    it "runs the guard before each poll of a function wait" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      replies_in_turn(fake, "Runtime.evaluate", [
        reply({result: {type: "boolean", value: false}}),
        reply({result: {type: "boolean", value: false}}),
        reply({result: {type: "boolean", value: true}}),
      ])
      polls_before = [] of Int32
      guard = -> { polls_before << fake.methods.count("Runtime.evaluate") }

      page.wait_for_function("window.ready", polling: 10.milliseconds, guard: guard)

      polls_before.should eq([0, 1, 2])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises the guard's exception unchanged and polls no more" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { reply({result: {type: "boolean", value: false}}) }
      fake.on("Runtime.callFunction") { reply({result: {type: "boolean", value: false}}) }
      {
        ChallengeSeen.new("challenge"),
        Crystalfaux::TimeoutError.new("the caller's own timeout"),
        Crystalfaux::ExecutionContextDestroyed.new("the caller's own error"),
      }.each do |raised|
        waits = {
          "Page#wait_for_function"  => {"Runtime.evaluate", -> { page.wait_for_function("window.ready", polling: 10.milliseconds, guard: guard_raising(raised)); nil }},
          "Frame#wait_for_selector" => {"Runtime.callFunction", -> { page.main_frame.wait_for_selector(".dialog", guard: guard_raising(raised)); nil }},
          "Page#wait_for_selector"  => {"Runtime.callFunction", -> { page.wait_for_selector(".dialog", guard: guard_raising(raised)); nil }},
          "Frame#wait_for_function" => {"Runtime.evaluate", -> { page.main_frame.wait_for_function("window.ready", polling: 10.milliseconds, guard: guard_raising(raised)); nil }},
        }
        waits.each do |name, (method, wait)|
          before = fake.methods.count(method)
          error = expect_raises(Exception) { wait.call }
          error.should be(raised), "#{name}: #{error.inspect}"
          page.wait_for_events_for_spec
          fake.methods.count(method).should eq(before + 1), name
        end
      end
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "ends the wait with TimeoutError when the guard runs past the deadline" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply({result: {type: "boolean", value: false}}) }

      expect_raises(Crystalfaux::TimeoutError, /\.dialog/) do
        page.wait_for_selector(".dialog", timeout: 100.milliseconds, guard: -> { sleep 150.milliseconds })
      end
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
