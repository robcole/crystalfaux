require "../spec_helper"
require "http/server"

# The page shapes of the Best Buy scraping trial (`examples/best_buy` on the
# `best-buy-scraper` branch): lazy slots that fill when they scroll into
# view and that a re-render replaces, dialogs that open and close late, and
# an overlay that covers a button. The pages' own scripts log what they see
# in DOM attributes, which the isolated world can read.
private PAGES = {
  "/grid" => <<-HTML,
    <!doctype html><title>grid</title>
    <style>body { margin: 0; } li { min-height: 700px; }</style>
    <h1>Graphics cards</h1>
    <ul id="grid"></ul>
    <script>
      const grid = document.getElementById('grid');
      for (let index = 0; index < 8; index++) {
        const slot = document.createElement('li');
        slot.dataset.slot = index;
        grid.append(slot);
      }
      const fill = slot => {
        const card = document.createElement('li');
        card.dataset.slot = slot.dataset.slot;
        card.innerHTML = '<a class="card" href="/product/' + slot.dataset.slot + '"><h3>Card ' + slot.dataset.slot + '</h3></a>';
        slot.replaceWith(card);
        // A framework re-render replaces the filled card once more.
        setTimeout(() => card.replaceWith(card.cloneNode(true)), 150);
      };
      const observer = new IntersectionObserver(entries => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          observer.unobserve(entry.target);
          setTimeout(() => fill(entry.target), 100);
        }
      });
      grid.querySelectorAll('li').forEach(slot => observer.observe(slot));
    </script>
    HTML
  "/pdp" => <<-HTML,
    <!doctype html><title>pdp</title>
    <style>
      body { margin: 0; }
      [role=dialog] { position: fixed; inset: 10% 20%; background: #fff; border: 1px solid; z-index: 5; }
    </style>
    <h1>PNY GeForce RTX 5090</h1>
    <a href="/pdp#reviews">Reviews</a>
    <label><input type="checkbox" id="protect"> Add protection</label>
    <span aria-hidden="true"><button>Hidden twin</button></span>
    <div style="height: 2400px">About this product</div>
    <button aria-label="See all specifications">Specifications</button>
    <div role="dialog" id="specs" aria-labelledby="specs-title" hidden>
      <h2 id="specs-title">Specifications</h2>
      <p>Brand: PNY</p>
      <button aria-label="Close">×</button>
    </div>
    <script>
      // The dialog opens 300 ms after the click and closes 200 ms after it.
      const specs = document.getElementById('specs');
      document.querySelector('[aria-label="See all specifications"]').addEventListener('click', event => {
        document.body.dataset.trusted = event.isTrusted;
        setTimeout(() => { specs.hidden = false; }, 300);
      });
      specs.querySelector('[aria-label=Close]').addEventListener('click', () => setTimeout(() => { specs.hidden = true; }, 200));
    </script>
    HTML
  "/covered" => <<-HTML,
    <!doctype html><title>covered</title>
    <style>#cover { position: fixed; inset: 0; background: rgba(0,0,0,.3); z-index: 10; }</style>
    <button id="buy" onclick="document.body.dataset.clicked = 'yes'">Add to cart</button>
    <div id="moving" style="position: absolute; top: 200px; animation: slide 1s linear infinite">Moving</div>
    <style>@keyframes slide { from { left: 0 } to { left: 300px } }</style>
    <div id="cover"></div>
    HTML
  "/framed" => <<-HTML,
    <!doctype html><title>framed</title>
    <style>
      body { margin: 0; }
      iframe { position: absolute; left: 50px; top: 40px; width: 300px; height: 200px; border: 5px solid; padding: 3px; }
      #cover { position: fixed; inset: 0; background: rgba(0,0,0,.3); }
    </style>
    <iframe src="/inner"></iframe>
    <div id="cover" onclick="document.body.dataset.coverClicked = 'yes'"></div>
    HTML
  "/inner" => <<-HTML,
    <!doctype html><title>inner</title>
    <style>body { margin: 0; } #target { position: absolute; left: 100px; top: 100px; }</style>
    <button id="target" onclick="document.body.dataset.clicked = 'yes'">Inner</button>
    HTML
  "/contents" => <<-HTML,
    <!doctype html><title>contents</title>
    <div id="hidden-text" style="display: contents; visibility: hidden">Invisible</div>
    <div id="override" style="display: contents; visibility: hidden"><span style="visibility: visible">Shown</span></div>
    <div id="empty" style="display: contents"></div>
    <button style="display: contents">Buy</button>
    <button style="display: contents; visibility: hidden">Ghost</button>
    <button aria-labelledby="real-name" aria-label="Label name">Content name</button>
    <span id="real-name">Labelled name</span>
    <button role="tab">Specs tab</button>
    <a href="/x">Visible <span style="display: none">secret</span>link</a>
    HTML
  "/second" => <<-HTML,
    <!doctype html><title>second</title><p id="late"></p>
    <script>setTimeout(() => { document.getElementById('late').textContent = 'ready'; }, 300)</script>
    HTML
}

private class ElementsServer
  getter base_url : String

  def initialize
    @server = HTTP::Server.new do |context|
      html = PAGES[context.request.path]?
      next context.response.respond_with_status(:not_found) unless html
      context.response.content_type = "text/html"
      context.response.print html
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @base_url = "http://127.0.0.1:#{address.port}"
    spawn(name: "elements-spec-server") { @server.listen }
  end

  def close : Nil
    @server.close
  end
end

private def open_page(binary : String) : {Crystalfaux::Browser, Crystalfaux::Page}
  browser = Crystalfaux::Browser.launch(Crystalfaux::Launcher::Options.new(executable: binary, headless: true))
  page = browser.new_context.new_page
  page.set_viewport_size(800, 600)
  {browser, page}
end

describe Crystalfaux::ElementHandle, tags: "browser" do
  it "reads a lazy grid by scrolling each slot into view" do
    binary = camoufox_binary
    server = ElementsServer.new
    browser, page = open_page(binary)
    page.goto("#{server.base_url}/grid")

    slots = page.query_selector_all("#grid > li")
    slots.size.should eq(8)
    titles = (0...slots.size).map do |index|
      selector = "#grid > li[data-slot='#{index}']"
      # The slot handle goes stale when the card replaces it; query again.
      page.query_selector(selector).should_not(be_nil).scroll_into_view_if_needed
      card = page.wait_for_selector("#{selector} a.card", timeout: 5.seconds).should_not(be_nil)
      card.inner_text
    end
    titles.should eq((0...8).map { |index| "Card #{index}" })

    # A re-rendered card detaches the old node: it stays readable, but it
    # cannot be scrolled to or clicked.
    stale = slots.first
    stale.text_content.should eq("")
    expect_raises(Crystalfaux::ElementDetached) { stale.scroll_into_view_if_needed }
    expect_raises(Crystalfaux::ElementDetached) { stale.click(timeout: 2.seconds) }
  ensure
    browser.try &.close
    server.try &.close
  end

  it "opens a late dialog with a click and closes it again" do
    binary = camoufox_binary
    server = ElementsServer.new
    browser, page = open_page(binary)
    page.goto("#{server.base_url}/pdp")

    page.get_by_role("heading").map(&.inner_text).should eq(["PNY GeForce RTX 5090"])
    page.get_by_role("link", name: "reviews", exact: false).size.should eq(1)
    page.get_by_role("checkbox", name: "Add protection").size.should eq(1)
    page.get_by_role("button", name: "Hidden twin").should be_empty
    page.get_by_role("dialog").should be_empty

    button = page.get_by_role("button", name: "See all specifications").first
    button.visible?.should be_true
    button.bounding_box.should_not(be_nil).y.should be > 600 # below the fold
    button.click
    page.evaluate("document.body.dataset.trusted").should eq(JSON::Any.new("true"))
    box = button.bounding_box.should_not(be_nil)
    (box.y + box.height > 0 && box.y < 600).should be_true # scrolled into view

    dialog = page.wait_for_selector("#specs", timeout: 5.seconds).should_not(be_nil)
    page.get_by_role("dialog", name: "Specifications").size.should eq(1)
    dialog.query_selector("p").should_not(be_nil).text_content.should eq("Brand: PNY")
    dialog.evaluate("(el, id) => el.id == id", "specs").should eq(JSON::Any.new(true))

    close = dialog.query_selector_all("button").first
    close.click
    page.wait_for_selector("#specs", state: :hidden, timeout: 5.seconds).should be_nil
    dialog.visible?.should be_false
    page.get_by_role("dialog").should be_empty
  ensure
    browser.try &.close
    server.try &.close
  end

  it "times out clicking a covered button, naming the cover" do
    binary = camoufox_binary
    server = ElementsServer.new
    browser, page = open_page(binary)
    page.goto("#{server.base_url}/covered")

    button = page.query_selector("#buy").should_not(be_nil)
    expect_raises(Crystalfaux::TimeoutError, %(covered by <div id="cover">)) { button.click(timeout: 1.second) }
    page.evaluate("document.body.dataset.clicked || null").should eq(JSON::Any.new(nil))

    moving = page.query_selector("#moving").should_not(be_nil)
    expect_raises(Crystalfaux::TimeoutError, "not stable") { moving.click(timeout: 1.second) }

    page.evaluate("document.getElementById('cover').remove()")
    button.click
    page.evaluate("document.body.dataset.clicked").should eq(JSON::Any.new("yes"))
  ensure
    browser.try &.close
    server.try &.close
  end

  it "does not click through a cover in a parent frame" do
    binary = camoufox_binary
    server = ElementsServer.new
    browser, page = open_page(binary)
    page.goto("#{server.base_url}/framed")
    frame = page.main_frame.children.first
    target = frame.wait_for_selector("#target", timeout: 5.seconds).should_not(be_nil)

    expect_raises(Crystalfaux::TimeoutError, %(covered by <div id="cover">)) { target.click(timeout: 500.milliseconds) }
    page.evaluate("document.body.dataset.coverClicked || null").should eq(JSON::Any.new(nil))
    frame.evaluate("document.body.dataset.clicked || null").should eq(JSON::Any.new(nil))

    page.evaluate("document.getElementById('cover').remove()")
    target.click
    frame.evaluate("document.body.dataset.clicked").should eq(JSON::Any.new("yes"))
  ensure
    browser.try &.close
    server.try &.close
  end

  it "applies visibility to display: contents elements and names by role" do
    binary = camoufox_binary
    server = ElementsServer.new
    browser, page = open_page(binary)
    page.goto("#{server.base_url}/contents")

    page.query_selector("#hidden-text").should_not(be_nil).visible?.should be_false
    page.query_selector("#override").should_not(be_nil).visible?.should be_true
    page.query_selector("#empty").should_not(be_nil).visible?.should be_false
    page.wait_for_selector("#hidden-text", state: :hidden, timeout: 1.second).should be_nil

    page.get_by_role("button", name: "Buy").size.should eq(1)
    page.get_by_role("button", name: "Ghost").should be_empty
    # aria-labelledby comes before aria-label and the content.
    page.get_by_role("button", name: "Labelled name").size.should eq(1)
    page.get_by_role("button", name: "Label name").should be_empty
    # An explicit role replaces the implicit one.
    page.get_by_role("button", name: "Specs tab").should be_empty
    page.get_by_role("tab", name: "Specs tab").size.should eq(1)
    # Hidden descendants are not part of the name.
    page.get_by_role("link", name: "Visible link").size.should eq(1)
  ensure
    browser.try &.close
    server.try &.close
  end

  it "waits through a navigation, and handles of the old document raise" do
    binary = camoufox_binary
    server = ElementsServer.new
    browser, page = open_page(binary)
    page.goto("#{server.base_url}/covered")
    button = page.query_selector("#buy").should_not(be_nil)

    outcome = async { page.wait_for_function("document.getElementById('late')?.textContent == 'ready' && location.pathname", 10.seconds) }
    page.goto("#{server.base_url}/second")

    receive_within(outcome, 10.seconds).should eq(JSON::Any.new("/second"))
    expect_raises(Crystalfaux::ExecutionContextDestroyed) { button.text_content }
    button.dispose
    expect_raises(Crystalfaux::TimeoutError, /never/) do
      page.wait_for_function("window.never", 300.milliseconds)
    end
  ensure
    browser.try &.close
    server.try &.close
  end
end
