require "../spec_helper"
require "http/server"

# The fixture of the Best Buy trial review
# (`plans/reviews/best-buy-scraper-review-f36229a.md`): when the trusted
# mouse move reaches the button, a `mousemove` listener inserts a visible,
# full-viewport `#px-captcha` overlay. The page logs each event and its
# target in a DOM attribute: `Page#evaluate` runs in a world apart from the
# page's scripts.
private CHALLENGE_ON_MOVE_HTML = <<-HTML
  <!DOCTYPE html>
  <title>Results</title><h1>RTX 5090</h1>
  <button id="more" style="margin:100px;width:200px;height:80px">More</button>
  <script>
    const log = [];
    const record = text => {
      log.push(text);
      document.body.dataset.log = JSON.stringify(log);
    };
    document.addEventListener('mousemove', event => {
      if (event.target.id !== 'more' || document.getElementById('px-captcha')) return;
      const challenge = document.createElement('div');
      challenge.id = 'px-captcha';
      challenge.style = 'position:fixed;inset:0;background:white;z-index:99999';
      challenge.textContent = 'Press and hold';
      document.body.append(challenge);
      record('challenge-visible=' + challenge.checkVisibility({visibilityProperty:true}));
    });
    for (const type of ['mousedown', 'mouseup', 'click']) {
      document.addEventListener(type, event => record(type + ':' + event.target.id));
    }
  </script>
  HTML

# What the caller's guard raises when the challenge is on the page.
private class ChallengeSeen < Exception
end

private def event_log(page : Crystalfaux::Page) : Array(String)
  JSON.parse(page.evaluate("document.body.dataset.log || '[]'").as_s).as_a.map(&.as_s)
end

describe "A click whose move shows a challenge", tags: "browser" do
  it "sends no press, release or click when the guard sees the challenge" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
    server = HTTP::Server.new do |context|
      context.response.content_type = "text/html"
      context.response.print CHALLENGE_ON_MOVE_HTML
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn(name: "click-guard-spec-server") { server.listen }
    browser = Crystalfaux::Browser.launch(options)
    page = browser.new_context.new_page
    guard = -> do
      raise ChallengeSeen.new("challenge") if page.query_selector("#px-captcha")
    end
    clicks = {
      "Mouse#click" => -> {
        box = page.query_selector("#more").should_not(be_nil).bounding_box.should_not(be_nil)
        page.mouse.click(box.x + box.width / 2, box.y + box.height / 2, guard: guard)
      },
      "ElementHandle#click" => -> {
        button = page.query_selector("#more").should_not(be_nil)
        button.click(timeout: 5.seconds, guard: guard)
      },
    }

    clicks.each do |name, click|
      page.goto("http://127.0.0.1:#{address.port}/")
      page.mouse.move(0, 0)

      expect_raises(ChallengeSeen) { click.call }

      event_log(page).should eq(["challenge-visible=true"]), name
    end
  ensure
    browser.try &.close
    server.try &.close
  end
end
