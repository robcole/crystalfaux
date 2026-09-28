require "../spec_helper"

describe Crystalfaux::Browser do
  describe ".connect" do
    it "enables the browser without the default context, then reads its info" do
      browser, fake = scripted_browser

      enable = fake.request("Browser.enable")
      enable["params"].should eq(JSON.parse(%({"attachToDefaultContext":false,"userPrefs":[]})))
      fake.methods.first(2).should eq(["Browser.enable", "Browser.getInfo"])
      browser.version.should eq("Firefox/152.0.4-beta.31")
      browser.user_agent.should start_with("Mozilla/5.0")
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#new_context" do
    it "creates a context that is removed when the pipe detaches" do
      browser, fake = scripted_browser

      context = browser.new_context

      fake.request("Browser.createBrowserContext")["params"].should eq(JSON.parse(%({"removeOnDetach":true})))
      context.id.should eq(ProbeScript::CONTEXT_ID)
      browser.contexts.should eq([context])
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#close" do
    it "sends Browser.close, then closes the pipe, and closes every context and page" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page

      browser.close

      fake.request("Browser.close")
      fake.peer.receive?.should be_nil
      browser.closed?.should be_true
      context.closed?.should be_true
      page.closed?.should be_true
      browser.contexts.should be_empty
      expect_raises(Crystalfaux::ConnectionClosed) { browser.new_context }
      expect_raises(Crystalfaux::ConnectionClosed) { page.evaluate("1") }
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "is safe to call more than once" do
      browser, fake = scripted_browser

      browser.close
      browser.close

      fake.request("Browser.close")
      expect_raises(Exception, /nothing received/) { fake.request("Browser.close", 50.milliseconds) }
    ensure
      fake.try &.close
    end

    it "fails a navigation that waits for its load" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.navigate") { [ProbeScript.navigate.first] }
      outcome = async { page.goto(ProbeScript::DATA_URL); JSON::Any.new(nil) }
      fake.request("Page.navigate")

      browser.close

      receive_within(outcome).should be_a(Crystalfaux::ConnectionClosed)
    ensure
      fake.try &.close
    end
  end

  describe "when the pipe closes" do
    it "fails a navigation in progress with ConnectionClosed and closes the pages" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.navigate") { [ProbeScript.navigate.first] }
      outcome = async { page.goto(ProbeScript::DATA_URL); JSON::Any.new(nil) }
      fake.request("Page.navigate")

      fake.close

      receive_within(outcome).should be_a(Crystalfaux::ConnectionClosed)
      browser.closed?.should be_true
      page.closed?.should be_true
    ensure
      browser.try &.close
    end

    it "fails a page that waits for its target" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.newPage") { [ProbeScript.reply_to("Browser.newPage")] }
      outcome = async { context.new_page; JSON::Any.new(nil) }
      fake.request("Browser.newPage")

      fake.close

      receive_within(outcome).should be_a(Crystalfaux::ConnectionClosed)
    ensure
      browser.try &.close
    end
  end
end
