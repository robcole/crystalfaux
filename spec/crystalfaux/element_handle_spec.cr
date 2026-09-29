require "../spec_helper"

private alias DomScripts = Crystalfaux::DomScripts

private def reply(result) : Array(JSON::Any)
  [json_frame({id: 0, result: result})]
end

private def error_reply(message : String) : Array(JSON::Any)
  [json_frame({id: 0, error: {message: message}})]
end

private def node(object_id : String)
  {result: {type: "object", subtype: "node", objectId: object_id}}
end

private def quad(x : Float64, y : Float64, width : Float64, height : Float64)
  {p1: {x: x, y: y}, p2: {x: x + width, y: y}, p3: {x: x + width, y: y + height}, p4: {x: x, y: y + height}}
end

# A loaded page and a handle to the element `#go`, whose object id is
# `obj-1` in the main frame's context `id-3`.
private def page_with_handle(browser : Crystalfaux::Browser, fake : ScriptedBrowser) : {Crystalfaux::Page, Crystalfaux::ElementHandle}
  page = loaded_page(browser)
  fake.on("Runtime.callFunction") { reply(node("obj-1")) }
  handle = page.query_selector("#go").should_not(be_nil)
  fake.request("Runtime.callFunction")
  {page, handle}
end

# A string result, such as the verdict of a hit test.
private def verdict(text : String)
  {result: {type: "string", value: text}}
end

# Answers each `Runtime.callFunction` with the block's result for its
# function declaration.
private def on_function(fake : ScriptedBrowser, &block : String, JSON::Any -> Array(JSON::Any)) : Nil
  fake.on("Runtime.callFunction") do |request|
    params = request["params"]
    block.call(params["functionDeclaration"].as_s, params)
  end
end

describe Crystalfaux::ElementHandle do
  describe "queries" do
    it "finds one element as a handle in the frame's isolated context" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply(node("obj-1")) }

      handle = page.query_selector("#go").should_not(be_nil)

      params = fake.request("Runtime.callFunction")["params"]
      params["executionContextId"].should eq("id-3")
      params["returnByValue"].should be_false
      params["args"].should eq(json_frame([{value: "#go"}]))
      handle.remote_object_id.should eq("obj-1")
      handle.frame.should be(page.main_frame)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "returns nil when no element matches" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply({result: {type: "object", subtype: "null", value: nil}}) }

      page.query_selector("#missing").should be_nil
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "finds all elements in order, and releases the array that held them" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.callFunction") { reply({result: {type: "object", subtype: "array", objectId: "list-1"}}) }
      fake.on("Runtime.getObjectProperties") do
        reply({properties: [
          {name: "1", value: {type: "object", subtype: "node", objectId: "obj-b"}},
          {name: "0", value: {type: "object", subtype: "node", objectId: "obj-a"}},
        ]})
      end

      page.query_selector_all("li").map(&.remote_object_id).should eq(%w[obj-a obj-b])

      fake.request("Runtime.getObjectProperties")["params"].should eq(json_frame({executionContextId: "id-3", objectId: "list-1"}))
      fake.request("Runtime.disposeObject")["params"].should eq(json_frame({executionContextId: "id-3", objectId: "list-1"}))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "queries the subtree of a handle with the handle as the root" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { reply(node("obj-2")) }

      handle.query_selector("span").should_not(be_nil).remote_object_id.should eq("obj-2")

      params = fake.request("Runtime.callFunction")["params"]
      params["args"].should eq(json_frame([{objectId: "obj-1"}, {value: "span"}]))
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#evaluate" do
    it "passes the element as the first argument, then the values" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { reply({result: {type: "string", value: "Buy"}}) }

      handle.evaluate("(el, suffix, n) => el.textContent + suffix + n", "!", 2).should eq(JSON::Any.new("Buy"))

      params = fake.request("Runtime.callFunction")["params"]
      params["executionContextId"].should eq("id-3")
      params["returnByValue"].should be_true
      params["args"].should eq(json_frame([{objectId: "obj-1"}, {value: "!"}, {value: 2}]))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises EvaluationError when the function throws" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { reply({exceptionDetails: {text: "Error: boom", stack: "@debugger eval"}}) }

      expect_raises(Crystalfaux::EvaluationError, /boom/) { handle.evaluate("el => { throw new Error('boom') }") }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ExecutionContextDestroyed after a navigation, without a request" do
      browser, fake = scripted_browser
      page, handle = page_with_handle(browser, fake)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-11", auxData: {frameId: ProbeScript::FRAME_ID, name: ""}})
      page.wait_for_events_for_spec

      expect_raises(Crystalfaux::ExecutionContextDestroyed) { handle.text_content }
      expect_raises(Crystalfaux::ExecutionContextDestroyed) { handle.bounding_box }
      fake.methods.count("Runtime.callFunction").should eq(1)
      fake.methods.should_not contain("Page.getContentQuads")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ExecutionContextDestroyed when the context goes during the call" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { [] of JSON::Any }
      outcome = async { handle.evaluate("el => new Promise(() => {})", timeout: 5.seconds) }
      fake.request("Runtime.callFunction")

      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::ExecutionContextDestroyed)
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#get_by_role" do
    it "queries by role with the handle as the root" do
      browser, fake = scripted_browser
      _, dialog = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { reply({result: {type: "object", subtype: "array", objectId: "list-1"}}) }
      fake.on("Runtime.getObjectProperties") do
        reply({properties: [{name: "0", value: {type: "object", subtype: "node", objectId: "obj-close"}}]})
      end

      dialog.get_by_role("button", name: "Close").map(&.remote_object_id).should eq(["obj-close"])

      params = fake.request("Runtime.callFunction")["params"]
      params["executionContextId"].should eq("id-3")
      params["functionDeclaration"].should eq(DomScripts::BY_ROLE)
      params["args"].should eq(json_frame([{value: "button"}, {value: "Close"}, {value: true}, {objectId: "obj-1"}]))
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "as an argument" do
    it "passes other handles of the same context as objectId arguments" do
      browser, fake = scripted_browser
      page, dialog = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { reply(node("obj-2")) }
      button = page.query_selector("button").should_not(be_nil)
      fake.request("Runtime.callFunction")
      fake.on("Runtime.callFunction") { reply({result: {type: "boolean", value: true}}) }

      dialog.evaluate("(el, other, n) => el.contains(other) && n", button, 2).should eq(JSON::Any.new(true))
      params = fake.request("Runtime.callFunction")["params"]
      params["args"].should eq(json_frame([{objectId: "obj-1"}, {objectId: "obj-2"}, {value: 2}]))

      page.evaluate("(a, b) => a.contains(b)", {dialog, button}).should eq(JSON::Any.new(true))
      params = fake.request("Runtime.callFunction")["params"]
      params["executionContextId"].should eq("id-3")
      params["returnByValue"].should be_true
      params["args"].should eq(json_frame([{objectId: "obj-1"}, {objectId: "obj-2"}]))

      page.main_frame.evaluate("(label, n) => label.repeat(n)", {"ab", 2}, 1.second)
      fake.request("Runtime.callFunction")["params"]["args"].should eq(json_frame([{value: "ab"}, {value: 2}]))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "rejects a disposed handle before it sends anything" do
      browser, fake = scripted_browser
      page, dialog = page_with_handle(browser, fake)
      fake.on("Runtime.callFunction") { reply(node("obj-2")) }
      button = page.query_selector("button").should_not(be_nil)
      button.dispose

      expect_raises(Crystalfaux::HandleDisposed) { dialog.evaluate("(el, other) => el.contains(other)", button) }
      expect_raises(Crystalfaux::HandleDisposed) { page.evaluate("el => el.id", {button}) }
      fake.methods.count("Runtime.callFunction").should eq(2)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "rejects a handle of another document before it sends anything" do
      browser, fake = scripted_browser
      page, stale = page_with_handle(browser, fake)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-11", auxData: {frameId: ProbeScript::FRAME_ID, name: ""}})
      page.wait_for_events_for_spec
      fake.on("Runtime.callFunction") { reply(node("obj-9")) }
      fresh = page.query_selector("#go").should_not(be_nil)

      expect_raises(Crystalfaux::ForeignHandle) { page.evaluate("el => el.id", {stale}) }
      expect_raises(Crystalfaux::ForeignHandle) { fresh.evaluate("(el, other) => el === other", stale) }
      fake.methods.count("Runtime.callFunction").should eq(2)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "rejects a handle of another frame before it sends anything" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Page.frameAttached", {frameId: "child-1", parentFrameId: ProbeScript::FRAME_ID})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-7", auxData: {frameId: "child-1", name: ""}})
      page.wait_for_events_for_spec
      fake.on("Runtime.callFunction") { reply(node("obj-1")) }
      inner = page.main_frame.children.first.query_selector("#go").should_not(be_nil)

      expect_raises(Crystalfaux::ForeignHandle) { page.evaluate("el => el.id", {inner}) }
      fake.methods.count("Runtime.callFunction").should eq(1)
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "reading" do
    it "reads the text, the attributes and the visibility by value" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) do |function, params|
        case function
        when DomScripts::TEXT_CONTENT then reply({result: {type: "string", value: " Buy  now "}})
        when DomScripts::INNER_TEXT   then reply({result: {type: "string", value: "Buy now"}})
        when DomScripts::VISIBLE      then reply({result: {type: "boolean", value: true}})
        when DomScripts::ATTRIBUTE
          params["args"][1]["value"] == "data-sku" ? reply({result: {type: "string", value: "123"}}) : reply({result: {type: "object", subtype: "null", value: nil}})
        else raise "unexpected function #{function}"
        end
      end

      handle.text_content.should eq(" Buy  now ")
      handle.inner_text.should eq("Buy now")
      handle.get_attribute("data-sku").should eq("123")
      handle.get_attribute("title").should be_nil
      handle.visible?.should be_true
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "measures the bounding box from the content quads" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      fake.on("Page.getContentQuads") { reply({quads: [quad(10, 20, 30, 4), quad(5, 24, 20, 6)]}) }

      handle.bounding_box.should eq(Crystalfaux::Protocol::Page::Rect.new(5, 20, 35, 10))

      fake.request("Page.getContentQuads")["params"].should eq(json_frame({frameId: ProbeScript::FRAME_ID, objectId: "obj-1"}))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "has no bounding box when the element has no layout" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      fake.on("Page.getContentQuads") { reply({quads: [] of String}) }

      handle.bounding_box.should be_nil
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#scroll_into_view_if_needed" do
    it "asks the browser to scroll the element's frame" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)

      handle.scroll_into_view_if_needed

      fake.request("Page.scrollIntoViewIfNeeded")["params"].should eq(json_frame({frameId: ProbeScript::FRAME_ID, objectId: "obj-1"}))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ElementDetached for a node that left the document" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      # What Camoufox `additions/juggler/content/PageAgent.js` replies.
      fake.on("Page.scrollIntoViewIfNeeded") { error_reply("Node is detached from document") }

      expect_raises(Crystalfaux::ElementDetached) { handle.scroll_into_view_if_needed }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#dispose" do
    it "releases the handle once, and later calls raise" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)

      handle.dispose
      handle.dispose

      fake.request("Runtime.disposeObject")["params"].should eq(json_frame({executionContextId: "id-3", objectId: "obj-1"}))
      fake.methods.count("Runtime.disposeObject").should eq(1)
      expect_raises(Crystalfaux::Error, /disposed/) { handle.text_content }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "sends nothing when the context is already gone" do
      browser, fake = scripted_browser
      page, handle = page_with_handle(browser, fake)
      fake.event("Runtime.executionContextDestroyed", {executionContextId: "id-3"})
      page.wait_for_events_for_spec

      handle.dispose

      fake.methods.should_not contain("Runtime.disposeObject")
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#click" do
    it "checks the element, scrolls it into view and clicks the centre of its first quad" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) do |function, _|
        case function
        when DomScripts::ACTIONABLE then reply({result: {type: "string", value: "done"}})
        when DomScripts::HIT_TARGET then reply(verdict("done"))
        else                             raise "unexpected function #{function}"
        end
      end
      fake.on("Page.getContentQuads") { reply({quads: [quad(100, 50, 40, 20)]}) }

      handle.click

      methods = fake.methods
      methods.index!("Page.scrollIntoViewIfNeeded").should be < methods.index!("Page.getContentQuads")
      events = Array.new(3) { fake.request("Page.dispatchMouseEvent")["params"] }
      events.map { |event| {event["type"].as_s, event["x"].as_f, event["y"].as_f} }.should eq([
        {"mousemove", 120.0, 60.0}, {"mousedown", 120.0, 60.0}, {"mouseup", 120.0, 60.0},
      ])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "retries until the deadline and names the element that covers it" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) do |function, _|
        case function
        when DomScripts::ACTIONABLE then reply({result: {type: "string", value: "done"}})
        when DomScripts::HIT_TARGET then reply(verdict(%(covered by <div id="cover">)))
        else                             raise "unexpected function #{function}"
        end
      end
      fake.on("Page.getContentQuads") { reply({quads: [quad(100, 50, 40, 20)]}) }

      expect_raises(Crystalfaux::TimeoutError, %(covered by <div id="cover">)) { handle.click(timeout: 300.milliseconds) }

      fake.methods.count(&.==("Page.getContentQuads")).should be > 1
      fake.methods.should_not contain("Page.dispatchMouseEvent")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "names the failed state check when it times out" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) { reply({result: {type: "string", value: "element is not visible"}}) }

      expect_raises(Crystalfaux::TimeoutError, "element is not visible") { handle.click(timeout: 200.milliseconds) }
      fake.methods.should_not contain("Page.scrollIntoViewIfNeeded")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "stops sending mouse events at the deadline" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) do |function, _|
        function == DomScripts::HIT_TARGET ? reply(verdict("done")) : reply({result: {type: "string", value: "done"}})
      end
      fake.on("Page.getContentQuads") { reply({quads: [quad(100, 50, 40, 20)]}) }
      # The fake serves one request at a time, so each input event takes 200 ms.
      fake.on("Page.dispatchMouseEvent") do
        sleep 200.milliseconds
        reply({} of String => String)
      end

      started = Time.instant
      expect_raises(Crystalfaux::TimeoutError) { handle.click(timeout: 100.milliseconds) }

      (Time.instant - started).should be < 180.milliseconds
      sleep 500.milliseconds
      fake.methods.count("Page.dispatchMouseEvent").should eq(1)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "releases the button and names the press when the press reply is late" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) do |function, _|
        function == DomScripts::HIT_TARGET ? reply(verdict("done")) : reply({result: {type: "string", value: "done"}})
      end
      fake.on("Page.getContentQuads") { reply({quads: [quad(100, 50, 40, 20)]}) }
      fake.on("Page.dispatchMouseEvent") do |request|
        request["params"]["type"] == "mousedown" ? [] of JSON::Any : reply({} of String => String)
      end

      error = expect_raises(Crystalfaux::TimeoutError) { handle.click(timeout: 300.milliseconds) }

      message = error.message.to_s
      message.should contain("mousedown")
      message.should_not contain("no check finished")
      events = Array.new(3) { fake.request("Page.dispatchMouseEvent")["params"] }
      events.map { |event| {event["type"].as_s, event["x"].as_f, event["y"].as_f, event["buttons"].as_i} }.should eq([
        {"mousemove", 120.0, 60.0, 0}, {"mousedown", 120.0, 60.0, 1}, {"mouseup", 120.0, 60.0, 0},
      ])
      sleep 300.milliseconds
      methods = fake.methods
      methods.count("Page.dispatchMouseEvent").should eq(3)
      methods.count("Page.scrollIntoViewIfNeeded").should eq(1)
      methods.count("Page.getContentQuads").should eq(1)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "checks that each ancestor frame lets the click reach the element's frame" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Page.frameAttached", {frameId: "child-1", parentFrameId: ProbeScript::FRAME_ID})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-7", auxData: {frameId: "child-1", name: ""}})
      page.wait_for_events_for_spec
      fake.on("Runtime.callFunction") { reply(node("obj-1")) }
      handle = page.main_frame.children.first.query_selector("#go").should_not(be_nil)
      on_function(fake) do |function, _|
        case function
        when DomScripts::ACTIONABLE       then reply({result: {type: "string", value: "done"}})
        when DomScripts::HIT_TARGET       then reply(verdict("done"))
        when DomScripts::FRAME_HIT_TARGET then reply(verdict(%(covered by <div id="cover">)))
        when DomScripts::FRAME_BOX        then reply({result: {type: "object", value: {width: 40, height: 20, left: 0, top: 0}}})
        else                                   raise "unexpected function #{function}"
        end
      end
      fake.on("Page.getContentQuads") { reply({quads: [quad(100, 50, 40, 20)]}) }
      fake.on("Page.adoptNode") { reply({remoteObject: {type: "object", subtype: "node", objectId: "owner-1"}}) }

      expect_raises(Crystalfaux::TimeoutError, %(covered by <div id="cover">)) { handle.click(timeout: 100.milliseconds) }

      fake.request("Page.adoptNode")["params"].should eq(json_frame({frameId: "child-1", executionContextId: "id-3"}))
      target_check = (1..8).each do
        params = fake.request("Runtime.callFunction")["params"]
        break params if params["functionDeclaration"] == DomScripts::HIT_TARGET
      end.should_not(be_nil)
      # The click point mapped into the child frame through its <iframe> quad.
      target_check["args"].should eq(json_frame([{objectId: "obj-1"}, {value: 20}, {value: 10}]))
      frame_check = (1..8).each do
        params = fake.request("Runtime.callFunction")["params"]
        break params if params["functionDeclaration"] == DomScripts::FRAME_HIT_TARGET
      end.should_not(be_nil)
      frame_check["executionContextId"].should eq("id-3")
      # The centre of the element's quad, in the main frame's viewport.
      frame_check["args"].should eq(json_frame([{objectId: "owner-1"}, {value: 120}, {value: 60}]))
      fake.request("Runtime.disposeObject")["params"].should eq(json_frame({executionContextId: "id-3", objectId: "owner-1"}))
      fake.methods.should_not contain("Page.dispatchMouseEvent")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "sends no click when the point cannot be mapped into an ancestor frame" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.event("Page.frameAttached", {frameId: "child-1", parentFrameId: ProbeScript::FRAME_ID})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-7", auxData: {frameId: "child-1", name: ""}})
      fake.event("Page.frameAttached", {frameId: "grandchild-1", parentFrameId: "child-1"})
      fake.event("Runtime.executionContextCreated", {executionContextId: "id-8", auxData: {frameId: "grandchild-1", name: ""}})
      page.wait_for_events_for_spec
      fake.on("Runtime.callFunction") { reply(node("obj-1")) }
      handle = page.main_frame.children.first.children.first.query_selector("#go").should_not(be_nil)
      on_function(fake) do |function, _|
        case function
        when DomScripts::FRAME_BOX then reply({result: {type: "object", value: {width: 100, height: 50, left: 0, top: 0}}})
        else                            reply(verdict("done"))
        end
      end
      fake.on("Page.adoptNode") { reply({remoteObject: {type: "object", subtype: "node", objectId: "owner-1"}}) }
      # The element's quad, then the child frame's <iframe> under a perspective.
      fake.on("Page.getContentQuads") do |request|
        if request["params"]["objectId"] == "owner-1"
          reply({quads: [{p1: {x: 0, y: 0}, p2: {x: 100, y: 0}, p3: {x: 90, y: 50}, p4: {x: 10, y: 60}}]})
        else
          reply({quads: [quad(40, 20, 20, 10)]})
        end
      end

      # The element's own frame is mapped first, through the same <iframe> quad.
      expect_raises(Crystalfaux::TimeoutError, "cannot be mapped into frame grandchild-1") { handle.click(timeout: 100.milliseconds) }
      fake.methods.should_not contain("Page.dispatchMouseEvent")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises ElementDetached at once for a node that left the document" do
      browser, fake = scripted_browser
      _, handle = page_with_handle(browser, fake)
      on_function(fake) { reply({result: {type: "string", value: "notconnected"}}) }

      expect_raises(Crystalfaux::ElementDetached) { handle.click(timeout: 5.seconds) }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
