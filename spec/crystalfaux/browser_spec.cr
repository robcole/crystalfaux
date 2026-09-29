require "../spec_helper"

# Handlers live inside the connection with no public view; this spec-only
# reader lets the specs prove the browser removes its own.
class Crystalfaux::Juggler::Connection
  def handler_count_for_spec : Int32
    @lock.synchronize { @subscriptions.sum(&.last.size) + @close_handlers.size }
  end
end

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

  describe ".connect with prefs" do
    it "sends bool, int and string prefs as userPrefs of Browser.enable" do
      connection, peer = connected_pair
      fake = ScriptedBrowser.new(peer)
      prefs = {
        "javascript.options.wasm" => JSON::Any.new(false),
        "media.autoplay.default"  => JSON::Any.new(5_i64),
        "intl.accept_languages"   => JSON::Any.new("fr-FR, fr"),
      }
      browser = Crystalfaux::Browser.connect(connection, prefs: prefs)

      enable = fake.request("Browser.enable")
      enable["params"]["userPrefs"].should eq(JSON.parse(<<-JSON))
        [{"name": "javascript.options.wasm", "value": false},
         {"name": "media.autoplay.default", "value": 5},
         {"name": "intl.accept_languages", "value": "fr-FR, fr"}]
        JSON

    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe ".connect" do
    it "removes its handlers from the connection when the handshake fails" do
      connection, peer = connected_pair
      fake = ScriptedBrowser.new(peer)
      fake.on("Browser.getInfo") { [JSON.parse(%({"id":0,"error":{"message":"no info"}}))] }

      expect_raises(Crystalfaux::ProtocolError, /no info/) { Crystalfaux::Browser.connect(connection) }

      connection.handler_count_for_spec.should eq(0)
      connection.closed?.should be_false
    ensure
      connection.try &.close
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

  describe ".connect with a proxy" do
    it "sets the browser proxy after Browser.enable and before Browser.getInfo" do
      connection, peer = connected_pair
      fake = ScriptedBrowser.new(peer)
      proxy = Crystalfaux::Proxy.new("proxy.test", 3128, type: :socks, username: "user", password: "secret",
        bypass: [".internal", "localhost"])

      browser = Crystalfaux::Browser.connect(connection, proxy: proxy)

      fake.methods.first(3).should eq(["Browser.enable", "Browser.setBrowserProxy", "Browser.getInfo"])
      fake.request("Browser.setBrowserProxy")["params"].should eq(JSON.parse(<<-JSON))
        {"type":"socks","bypass":[".internal","localhost"],"host":"proxy.test","port":3128,
         "username":"user","password":"secret"}
        JSON

    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "#new_context with a proxy" do
    it "sets the proxy of the new context before returning it" do
      browser, fake = scripted_browser

      context = browser.new_context(proxy: Crystalfaux::Proxy.new("127.0.0.1", 8080))

      fake.methods.last(2).should eq(["Browser.createBrowserContext", "Browser.setContextProxy"])
      fake.request("Browser.setContextProxy")["params"].should eq(JSON.parse(<<-JSON))
        {"browserContextId":"#{ProbeScript::CONTEXT_ID}","type":"http","bypass":[],"host":"127.0.0.1","port":8080}
        JSON
      browser.contexts.should eq([context])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "removes the context and raises when the browser rejects the proxy" do
      browser, fake = scripted_browser
      fake.on("Browser.setContextProxy") { [JSON.parse(%({"id":0,"error":{"message":"bad proxy"}}))] }

      expect_raises(Crystalfaux::ProtocolError, /bad proxy/) do
        browser.new_context(proxy: Crystalfaux::Proxy.new("127.0.0.1", 8080))
      end

      fake.request("Browser.removeBrowserContext")["params"].should eq(JSON.parse(%({"browserContextId":"#{ProbeScript::CONTEXT_ID}"})))
      browser.contexts.should be_empty
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

    it "removes the browser's handlers from the connection" do
      browser, fake = scripted_browser
      connection = browser.connection
      connection.handler_count_for_spec.should be > 0

      browser.close

      connection.handler_count_for_spec.should eq(0)
    ensure
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
