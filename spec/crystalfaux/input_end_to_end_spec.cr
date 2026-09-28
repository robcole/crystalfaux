require "../spec_helper"
require "http/server"

# A page taller than the viewport, with a gradient so that parts of it look
# different. It logs the modifier flags of each mousedown and keydown in a
# DOM attribute: Camoufox evaluates in a world apart from the page's
# scripts, so their globals are not visible to `Page#evaluate`.
private PAGE_HTML = <<-HTML
  <!DOCTYPE html>
  <title>input</title>
  <style>
    html, body { margin: 0; }
    body { height: 2400px; background: linear-gradient(#fff, #036); }
  </style>
  <button id="go" style="position: absolute; left: 40px; top: 30px; width: 120px; height: 40px"
    onclick="this.textContent = 'clicked ' + event.detail">Click me</button>
  <input id="name" style="position: absolute; left: 40px; top: 100px; width: 200px">
  <script>
    const events = [];
    const log = (event) => {
      events.push([event.type, event.key || null, event.shiftKey, event.ctrlKey, event.altKey, event.metaKey]);
      document.body.dataset.events = JSON.stringify(events);
    };
    document.addEventListener("mousedown", log);
    document.addEventListener("keydown", log);
  </script>
  HTML

private PNG_SIGNATURE  = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
private JPEG_SIGNATURE = Bytes[0xFF, 0xD8, 0xFF]

# The center of the element that *selector* finds, in CSS pixels.
private def center_of(page : Crystalfaux::Page, selector : String) : {Float64, Float64}
  box = page.evaluate("(() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); " \
                      "return [r.x + r.width / 2, r.y + r.height / 2]; })()").as_a
  {box[0].as_f, box[1].as_f}
end

# The width and height of a PNG, from its IHDR chunk.
private def png_size(png : Bytes) : {Int32, Int32}
  png[0, PNG_SIGNATURE.size].should eq(PNG_SIGNATURE)
  {IO::ByteFormat::BigEndian.decode(Int32, png[16, 4]), IO::ByteFormat::BigEndian.decode(Int32, png[20, 4])}
end

# Returns the events logged since the last call.
private def take_events(page : Crystalfaux::Page, seen : Array(JSON::Any)) : Array(JSON::Any)
  all = JSON.parse(page.evaluate("document.body.dataset.events || '[]'").as_s).as_a
  fresh = all[seen.size..]
  seen.concat(fresh)
  fresh
end

describe Crystalfaux::Page, tags: "browser" do
  it "clicks, types, scrolls and takes screenshots in a real Camoufox" do
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

    # Each modifier reaches the page as its own flag: shift, ctrl, alt, meta.
    seen = [] of JSON::Any
    take_events(page, seen)
    %w[Shift Control Alt Meta].each do |key|
      page.keyboard.down(key)
      page.mouse.click(x, y)
      page.keyboard.up(key)
    end
    take_events(page, seen).select(&.[0].==("mousedown")).map(&.as_a[2..]).should eq(JSON.parse(
      "[[true, false, false, false], [false, true, false, false], [false, false, true, false], [false, false, false, true]]").as_a)

    x, y = center_of(page, "#name")
    page.mouse.click(x, y)
    page.keyboard.type("Hi, crystal")
    take_events(page, seen)
    page.keyboard.press("Shift+ArrowLeft")
    take_events(page, seen).should eq(JSON.parse(
      %([["keydown", "Shift", true, false, false, false], ["keydown", "ArrowLeft", true, false, false, false]])).as_a)
    page.keyboard.press("Backspace")
    page.keyboard.insert_text("é!")
    page.evaluate("document.querySelector('#name').value").should eq(JSON::Any.new("Hi, crystaé!"))

    top = page.screenshot
    png_size(top).should eq({640, 480})
    png_size(page.screenshot(full_page: true)).should eq({640, 2400})

    page.mouse.move(320, 240)
    page.mouse.wheel(0, 600)
    scroll_y = 0_i64
    deadline = Time.instant + 5.seconds
    until scroll_y > 0 || Time.instant > deadline
      scroll_y = page.evaluate("scrollY").as_i64
    end
    scroll_y.should be > 0
    scrolled = page.screenshot
    png_size(scrolled).should eq({640, 480})
    scrolled.should_not eq(top)

    clip = Crystalfaux::Protocol::Page::Clip.new(40, 30, 120, 40)
    jpeg = page.screenshot(clip: clip, format: :jpeg, quality: 70)
    jpeg[0, JPEG_SIGNATURE.size].should eq(JPEG_SIGNATURE)
  ensure
    browser.try &.close
    server.try &.close
  end
end
