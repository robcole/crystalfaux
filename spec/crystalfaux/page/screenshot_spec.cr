require "../../spec_helper"

private PNG_BYTES = Bytes[0x89, 0x50, 0x4E, 0x47]

private def screenshot_reply : Array(JSON::Any)
  [json_frame({id: 0, result: {data: Base64.strict_encode(PNG_BYTES)}})]
end

private def evaluation_reply(value) : Array(JSON::Any)
  [json_frame({id: 0, result: {result: {value: value}}})]
end

describe Crystalfaux::Page do
  describe "#screenshot" do
    it "captures a clip in document coordinates and decodes the image" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Page.screenshot") { screenshot_reply }

      clip = Crystalfaux::Protocol::Page::Clip.new(10, 20, 300, 150)
      page.screenshot(format: :jpeg, quality: 80, clip: clip).should eq(PNG_BYTES)

      fake.request("Page.screenshot")["params"].should eq(json_frame({
        mimeType: "image/jpeg", clip: {x: 10.0, y: 20.0, width: 300.0, height: 150.0}, quality: 80,
      }))
      fake.methods.should_not contain("Runtime.evaluate")
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "captures the whole document for a full page" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { evaluation_reply({x: 0, y: 0, width: 800, height: 2400}) }
      fake.on("Page.screenshot") { screenshot_reply }

      page.screenshot(full_page: true)

      fake.request("Page.screenshot")["params"].should eq(json_frame({
        mimeType: "image/png", clip: {x: 0.0, y: 0.0, width: 800.0, height: 2400.0},
      }))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "captures the visible viewport where it is scrolled to" do
      browser, fake = scripted_browser
      page = loaded_page(browser)
      fake.on("Runtime.evaluate") { evaluation_reply({x: 0, y: 500, width: 1280, height: 720}) }
      fake.on("Page.screenshot") { screenshot_reply }

      page.screenshot

      fake.request("Page.screenshot")["params"]["clip"].should eq(
        json_frame({x: 0.0, y: 500.0, width: 1280.0, height: 720.0}))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "rejects a quality for PNG" do
      browser, fake = scripted_browser
      page = loaded_page(browser)

      expect_raises(ArgumentError, /quality/) { page.screenshot(format: :png, quality: 50) }
      expect_raises(ArgumentError, /quality/) { page.screenshot(format: :jpeg, quality: 101) }
      page.wait_for_events_for_spec
      fake.methods.should_not contain("Page.screenshot")
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#set_viewport_size" do
    it "sets the viewport of the page" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page

      page.set_viewport_size(1024, 768)

      fake.request("Page.setViewportSize")["params"].should eq(
        json_frame({viewportSize: {width: 1024.0, height: 768.0}}))
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
