require "../spec_helper"
require "http/server"

private PAGE_HTML = <<-HTML
  <!DOCTYPE html>
  <title>input</title>
  <button id="go" style="position: absolute; left: 40px; top: 30px; width: 120px; height: 40px"
    onclick="this.textContent = 'clicked ' + event.detail">Click me</button>
  <input id="name" style="position: absolute; left: 40px; top: 100px; width: 200px">
  HTML

private PNG_SIGNATURE  = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
private JPEG_SIGNATURE = Bytes[0xFF, 0xD8, 0xFF]

# The center of the element that *selector* finds, in CSS pixels.
private def center_of(page : Crystalfaux::Page, selector : String) : {Float64, Float64}
  box = page.evaluate("(() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); " \
                      "return [r.x + r.width / 2, r.y + r.height / 2]; })()").as_a
  {box[0].as_f, box[1].as_f}
end

describe Crystalfaux::Page, tags: "browser" do
  it "clicks, types and takes screenshots in a real Camoufox" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
    server = HTTP::Server.new do |context|
      context.response.content_type = "text/html"
      context.response.print PAGE_HTML
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn(name: "input-spec-server") { server.listen }
    browser = Crystalfaux::Browser.launch(options)
    page = browser.new_context.new_page
    page.set_viewport_size(640, 480)
    page.goto("http://127.0.0.1:#{address.port}/")

    page.evaluate("[innerWidth, innerHeight]").should eq(JSON.parse("[640, 480]"))

    x, y = center_of(page, "#go")
    page.mouse.click(x, y)
    page.evaluate("document.querySelector('#go').textContent").should eq(JSON::Any.new("clicked 1"))

    x, y = center_of(page, "#name")
    page.mouse.click(x, y)
    page.keyboard.type("Hi, crystal")
    page.keyboard.press("Shift+ArrowLeft")
    page.keyboard.press("Backspace")
    page.keyboard.insert_text("é!")
    page.evaluate("document.querySelector('#name').value").should eq(JSON::Any.new("Hi, crystaé!"))

    png = page.screenshot
    png[0, PNG_SIGNATURE.size].should eq(PNG_SIGNATURE)
    full = page.screenshot(full_page: true)
    full[0, PNG_SIGNATURE.size].should eq(PNG_SIGNATURE)
    clip = Crystalfaux::Protocol::Page::Clip.new(40, 30, 120, 40)
    jpeg = page.screenshot(clip: clip, format: :jpeg, quality: 70)
    jpeg[0, JPEG_SIGNATURE.size].should eq(JPEG_SIGNATURE)
    jpeg.size.should be < png.size
  ensure
    browser.try &.close
    server.try &.close
  end
end
