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

    it "times out when the page never becomes ready" do
      browser, fake = scripted_browser
      context = browser.new_context
      fake.on("Browser.newPage") { ProbeScript.new_page.reject(&.["method"]?.==("Page.ready")) }

      expect_raises(Crystalfaux::TimeoutError) { context.new_page(timeout: 100.milliseconds) }
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
