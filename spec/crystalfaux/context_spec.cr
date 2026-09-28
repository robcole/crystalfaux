require "../spec_helper"

describe Crystalfaux::Context do
  describe "#new_page" do
    it "returns the page of the attached target once it is ready" do
      browser, fake = scripted_browser
      context = browser.new_context

      page = context.new_page

      fake.request("Browser.newPage")["params"].should eq(JSON.parse(%({"browserContextId":"#{ProbeScript::CONTEXT_ID}"})))
      page.target_id.should eq(ProbeScript::TARGET_ID)
      page.context.should be(context)
      page.url.should eq("about:blank")
      context.pages.should eq([page])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "waits for the attach event when the reply comes first" do
      browser, fake = scripted_browser
      context = browser.new_context
      reply = ProbeScript.reply_to("Browser.newPage")
      fake.on("Browser.newPage") { [reply] + ProbeScript.new_page.reject(&.["id"]?) }

      page = context.new_page

      page.target_id.should eq(ProbeScript::TARGET_ID)
      page.main_frame.id.should eq(ProbeScript::FRAME_ID)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "closes the target and forgets the page when it never becomes ready" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.newPage") { ProbeScript.new_page.reject(&.["method"]?.==("Page.ready")) }
      # The page is registered while `new_page` waits; catch it to check it
      # afterwards.
      seen = Channel(Crystalfaux::Page).new(1)
      spawn do
        until page = browser.pages.first?
          Fiber.yield
        end
        seen.send(page)
      end

      expect_raises(Crystalfaux::TimeoutError) { context.new_page(timeout: 100.milliseconds) }

      page = receive_within(seen)
      fake.request("Page.close")["sessionId"].should eq(ProbeScript::SESSION_ID)
      page.closed?.should be_true
      browser.pages.should be_empty
      context.pages.should be_empty
      fake.event("Page.navigationCommitted", {frameId: ProbeScript::FRAME_ID, navigationId: "nav-9", url: "about:blank#late", name: ""})
      page.wait_for_events_for_spec
      page.url.should eq("about:blank")
      context.closed?.should be_false
      browser.closed?.should be_false
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "closes a target that attaches after the wait for it timed out" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.newPage") { [ProbeScript.reply_to("Browser.newPage")] }
      expect_raises(Crystalfaux::TimeoutError) { context.new_page(timeout: 50.milliseconds) }

      ProbeScript.new_page.reject(&.["id"]?).each { |message| fake.peer.raw(message.to_json) }

      fake.request("Page.close")["sessionId"].should eq(ProbeScript::SESSION_ID)
      browser.pages.should be_empty
      context.closed?.should be_false
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises PageClosed when the page attaches and detaches before the reply" do
      browser, fake = scripted_browser
      context = browser.new_context
      detach = json_frame({method: "Browser.detachedFromTarget",
                           params: {sessionId: ProbeScript::SESSION_ID, targetId: ProbeScript::TARGET_ID}})
      reply = ProbeScript.reply_to("Browser.newPage")
      fake.on("Browser.newPage") { ProbeScript.new_page.reject(&.["id"]?) + [detach, reply] }
      outcome = async { context.new_page(timeout: 5.seconds); JSON::Any.new(nil) }

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageClosed)
      browser.pages.should be_empty
      context.closed?.should be_false
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises PageClosed when the context closes before the reply" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.newPage") { [] of JSON::Any }
      outcome = async { context.new_page(timeout: 5.seconds); JSON::Any.new(nil) }
      fake.request("Browser.newPage")

      context.close

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageClosed)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises PageClosed when the context closes while waiting for the attach" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.newPage") { [ProbeScript.reply_to("Browser.newPage")] }
      outcome = async { context.new_page(timeout: 5.seconds); JSON::Any.new(nil) }
      fake.request("Browser.newPage")
      sleep 20.milliseconds # let the reply reach the waiting call

      context.close

      receive_within(outcome, 500.milliseconds).should be_a(Crystalfaux::PageClosed)
      # A late attach does not register a page in the closed context.
      ProbeScript.new_page.reject(&.["id"]?).each { |message| fake.peer.raw(message.to_json) }
      browser.new_context # a round trip, after the attach was handled
      browser.pages.should be_empty
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#close" do
    it "removes the browser context and closes its pages" do
      browser, fake = scripted_browser
      context = browser.new_context
      page = context.new_page

      context.close
      context.close

      request = fake.request("Browser.removeBrowserContext")
      request["params"].should eq(JSON.parse(%({"browserContextId":"#{ProbeScript::CONTEXT_ID}"})))
      fake.methods.count("Browser.removeBrowserContext").should eq(1)
      context.closed?.should be_true
      page.closed?.should be_true
      browser.contexts.should be_empty
      expect_raises(Crystalfaux::Error, /closed/) { context.new_page }
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
