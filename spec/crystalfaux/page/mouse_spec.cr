require "../../spec_helper"

# Returns the params of the next *count* requests for *method*.
private def params_of(fake : ScriptedBrowser, method : String, count : Int32) : Array(JSON::Any)
  Array.new(count) { fake.request(method)["params"] }
end

describe Crystalfaux::Page::Mouse do
  it "clicks with a move, a down and an up at the point" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.mouse.click(10.5, 20)

    params_of(fake, "Page.dispatchMouseEvent", 3).should eq([
      json_frame({type: "mousemove", button: 0, x: 10.0, y: 20.0, modifiers: 0, buttons: 0}),
      json_frame({type: "mousedown", button: 0, x: 10.0, y: 20.0, modifiers: 0, clickCount: 1, buttons: 1}),
      json_frame({type: "mouseup", button: 0, x: 10.0, y: 20.0, modifiers: 0, clickCount: 1, buttons: 0}),
    ])
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "reports held buttons while it moves, and a double click as two clicks" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page
    mouse = page.mouse

    mouse.down(button: :right)
    mouse.move(4, 8, steps: 2)
    mouse.up(button: :right)
    mouse.click(4, 8, click_count: 2)

    params_of(fake, "Page.dispatchMouseEvent", 9).map { |event| {event["type"], event["x"], event["buttons"], event["clickCount"]?} }.should eq([
      {"mousedown", 0.0, 2, 1},
      {"mousemove", 2.0, 2, nil},
      {"mousemove", 4.0, 2, nil},
      {"mouseup", 4.0, 0, 1},
      {"mousemove", 4.0, 0, nil},
      {"mousedown", 4.0, 1, 1},
      {"mouseup", 4.0, 0, 1},
      {"mousedown", 4.0, 1, 2},
      {"mouseup", 4.0, 0, 2},
    ].map { |type, x, buttons, count| {JSON::Any.new(type), JSON::Any.new(x), JSON::Any.new(buttons.to_i64), count.try { |value| JSON::Any.new(value.to_i64) }} })
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "waits for an animation frame, then scrolls at its position with held modifiers" do
    browser, fake = scripted_browser
    page = loaded_page(browser)
    fake.on("Runtime.evaluate") { [json_frame({id: 0, result: {} of String => String})] }

    page.mouse.move(30, 40)
    page.keyboard.down("Shift")
    page.mouse.wheel(0, 120)

    fake.request("Runtime.evaluate")["params"]["expression"].should eq(JSON::Any.new("new Promise(requestAnimationFrame)"))
    fake.request("Page.dispatchWheelEvent")["params"].should eq(
      json_frame({x: 30.0, y: 40.0, deltaX: 0.0, deltaY: 120.0, deltaZ: 0.0, modifiers: 4}))
    methods = fake.methods
    methods.index!("Runtime.evaluate").should be < methods.index!("Page.dispatchWheelEvent")
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "sends each held modifier as Firefox's modifier bit" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    expected = {"Alt" => 1, "Control" => 2, "Shift" => 4, "Meta" => 8}
    sent = expected.keys.to_h do |key|
      page.keyboard.down(key)
      page.mouse.down
      page.mouse.up
      page.keyboard.up(key)
      down, up = Array.new(2) { fake.request("Page.dispatchMouseEvent")["params"]["modifiers"].as_i }
      down.should eq(up)
      {key, down}
    end

    sent.should eq(expected)
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "raises PageCrashed on a crashed page" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page
    fake.event("Page.crashed", {} of String => String)
    page.wait_for_events_for_spec

    expect_raises(Crystalfaux::PageCrashed) { page.mouse.click(1, 1) }
  ensure
    browser.try &.close
    fake.try &.close
  end
end
