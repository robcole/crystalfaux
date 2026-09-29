require "../spec_helper"
require "http/server"

# A button whose `mousedown` listener is busy for 700 ms, so Juggler
# acknowledges the press after a 500 ms click has timed out. The page logs
# the `buttons` of each `mousemove` and `mouseup` in a DOM attribute:
# `Page#evaluate` runs in a world apart from the page's scripts.
private SLOW_PRESS_HTML = <<-HTML
  <!DOCTYPE html>
  <title>press</title>
  <style>html, body { margin: 0; }</style>
  <button id="b" style="position: absolute; left: 0; top: 0; width: 200px; height: 80px">Press</button>
  <script>
    const log = [];
    const record = (entry) => { log.push(entry); document.body.dataset.log = JSON.stringify(log); };
    const b = document.getElementById('b');
    b.addEventListener('mousedown', () => {
      record('down');
      const end = performance.now() + 700;
      while (performance.now() < end);
    });
    document.addEventListener('mouseup', () => record('up'));
    document.addEventListener('mousemove', (event) => record('move ' + event.buttons));
  </script>
  HTML

# The page's log of mouse events.
private def mouse_log(page : Crystalfaux::Page) : Array(String)
  JSON.parse(page.evaluate("document.body.dataset.log || '[]'").as_s).as_a.map(&.as_s)
end

# Waits until the page has logged a `mouseup`, then returns the log.
private def log_with_release(page : Crystalfaux::Page) : Array(String)
  deadline = Time.instant + 5.seconds
  loop do
    log = mouse_log(page)
    return log if log.includes?("up") || Time.instant > deadline
    sleep 50.milliseconds
  end
end

describe "A click whose press times out", tags: "browser" do
  it "releases the button for each click API" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
    server = HTTP::Server.new do |context|
      context.response.content_type = "text/html"
      context.response.print SLOW_PRESS_HTML
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn(name: "click-release-spec-server") { server.listen }
    browser = Crystalfaux::Browser.launch(options)
    page = browser.new_context.new_page
    clicks = {
      "Mouse#click"         => -> { page.mouse.click(100, 40, timeout: 500.milliseconds) },
      "ElementHandle#click" => -> {
        button = page.query_selector("#b").should_not(be_nil)
        button.click(timeout: 500.milliseconds)
      },
    }

    clicks.each do |name, click|
      page.goto("http://127.0.0.1:#{address.port}/")

      error = expect_raises(Crystalfaux::TimeoutError) { click.call }
      error.message.to_s.should contain("mousedown")
      error.message.to_s.should_not contain("no check finished")

      log_with_release(page).should contain("up"), name
      page.mouse.move(150, 60)
      mouse_log(page).last.should eq("move 0"), name
    end
  ensure
    browser.try &.close
    server.try &.close
  end
end
