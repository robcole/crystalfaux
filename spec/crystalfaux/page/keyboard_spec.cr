require "../../spec_helper"

private def key_events(fake : ScriptedBrowser, count : Int32) : Array(JSON::Any)
  Array.new(count) { fake.request("Page.dispatchKeyEvent")["params"] }
end

private def key_event(type : String, key : String, code : String, key_code : Int32,
                      text : String? = nil, location : Int32 = 0) : JSON::Any
  event = {"type" => type, "key" => key, "keyCode" => key_code, "location" => location, "code" => code, "repeat" => false, "text" => text}
  json_frame(event.compact)
end

describe Crystalfaux::Page::Keyboard do
  it "types each character as a key press with its text" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.keyboard.type("aB")

    key_events(fake, 4).should eq([
      key_event("keydown", "a", "KeyA", 65, "a"),
      key_event("keyup", "a", "KeyA", 65),
      key_event("keydown", "B", "KeyB", 66, "B"),
      key_event("keyup", "B", "KeyB", 66),
    ])
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "inserts characters that have no key as text" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.keyboard.type("é")

    fake.request("Page.insertText")["params"].should eq(json_frame({text: "é"}))
    fake.methods.should_not contain("Page.dispatchKeyEvent")
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "presses a combination: modifiers down, the key, then modifiers up in reverse" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.keyboard.press("Shift+a")

    key_events(fake, 4).should eq([
      key_event("keydown", "Shift", "ShiftLeft", 16, location: 1),
      key_event("keydown", "A", "KeyA", 65, "A"),
      key_event("keyup", "A", "KeyA", 65),
      key_event("keyup", "Shift", "ShiftLeft", 16, location: 1),
    ])
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "sends no text while a modifier other than Shift is held" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.keyboard.press("Control+Shift+a")

    key_events(fake, 3)[2].should eq(key_event("keydown", "A", "KeyA", 65))
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "presses named keys and the plus key" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.keyboard.press("Enter")
    page.keyboard.press("ArrowLeft")
    page.keyboard.press("+")

    downs = key_events(fake, 6).select(&.["type"].==("keydown"))
    downs.should eq([
      # Firefox makes the text of Enter itself (Playwright `ffInput.ts`).
      key_event("keydown", "Enter", "Enter", 13),
      key_event("keydown", "ArrowLeft", "ArrowLeft", 37),
      key_event("keydown", "+", "Equal", 187, "+"),
    ])
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "marks a key that is already down as a repeat" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.keyboard.down("a")
    page.keyboard.down("a")

    key_events(fake, 2).map(&.["repeat"].as_bool).should eq([false, true])
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "rejects an unknown key without sending anything" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    expect_raises(ArgumentError, /Unknown key: "Hyper"/) { page.keyboard.press("Hyper") }
    page.wait_for_events_for_spec
    fake.methods.should_not contain("Page.dispatchKeyEvent")
  ensure
    browser.try &.close
    fake.try &.close
  end
end
