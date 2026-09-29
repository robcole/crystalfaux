require "../spec_helper"

describe Crystalfaux::Browser, tags: "browser" do
  it "reproduces the probe against a real Camoufox and shuts down cleanly" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
    started = Time.instant
    browser = Crystalfaux::Browser.launch(options)
    process = browser.process.should_not be_nil
    browser.version.should start_with("Firefox/")

    page = browser.new_context.new_page
    page.goto("data:text/html,<title>crystalfaux</title>")

    page.url.should eq("data:text/html,<title>crystalfaux</title>")
    page.title.should eq("crystalfaux")
    page.content.should contain("<title>crystalfaux</title>")
    page.evaluate("navigator.webdriver").should eq(JSON::Any.new(false))
    page.evaluate("navigator.userAgent").as_s.should start_with("Mozilla/5.0")
    size = page.evaluate("[screen.width, screen.height]").as_a.map(&.as_i)
    size.size.should eq(2)
    size.each(&.should(be > 0))
    expect_raises(Crystalfaux::EvaluationError, "boom") { page.evaluate("throw new Error('boom')") }

    browser.close

    process.exited?.should be_true
    Dir.exists?(process.profile_dir).should be_false
    (Time.instant - started).should be < 30.seconds
  ensure
    browser.try &.close
  end
end

describe "Crystalfaux::Browser.launch with prefs", tags: "browser" do
  it "applies a pref that a page can observe" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true,
      prefs: {"javascript.options.wasm" => JSON::Any.new(false)})
    browser = Crystalfaux::Browser.launch(options)
    page = browser.new_context.new_page
    page.goto("data:text/html,<title>prefs</title>")

    page.evaluate("typeof WebAssembly").should eq(JSON::Any.new("undefined"))
  ensure
    browser.try &.close
  end
end
