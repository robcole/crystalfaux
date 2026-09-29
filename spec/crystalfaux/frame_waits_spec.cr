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
end
