require "../spec_helper"
require "http/server"

private USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:152.0) Gecko/20100101 Firefox/152.0"

# A plain HTTP forward proxy for `http://` URLs only: it records each request
# target, which a client sends as an absolute URL, with its `User-Agent`, and
# answers with a page instead of forwarding.
private class ForwardProxy
  getter port : Int32
  getter requests = Channel({String, String?}).new(16)

  def initialize
    @server = HTTP::Server.new do |context|
      request = context.request
      @requests.send({request.resource, request.headers["User-Agent"]?})
      context.response.content_type = "text/html"
      context.response.print %(<!DOCTYPE html><title>via proxy #{request.headers["Host"]?}</title>)
    end
    @port = @server.bind_tcp("127.0.0.1", 0).port
    spawn(name: "forward-proxy") { @server.listen }
  end

  def close : Nil
    @server.close
  end
end

describe "fingerprint configs and proxies", tags: "browser" do
  it "reports the configured screen size and user agent" do
    config = Crystalfaux::Fingerprint::Config.for(os: :mac, screen: Crystalfaux::Fingerprint::Screen.new(1366, 768),
      user_agent: USER_AGENT)
    browser = Crystalfaux::Browser.launch(config: config,
      options: Crystalfaux::Launcher::Options.new(executable: camoufox_binary))
    page = browser.new_context.new_page

    page.evaluate("[screen.width, screen.height, screen.availHeight]").should eq(JSON.parse("[1366, 768, 743]"))
    page.evaluate("navigator.userAgent").should eq(JSON::Any.new(USER_AGENT))
    page.evaluate("navigator.platform").should eq(JSON::Any.new("MacIntel"))
  ensure
    browser.try &.close
  end

  it "applies an integer key given as an integer-valued float" do
    config = Crystalfaux::Fingerprint::Config.from_json(%({"navigator.hardwareConcurrency": 3.0}))
    browser = Crystalfaux::Browser.launch(config: config,
      options: Crystalfaux::Launcher::Options.new(executable: camoufox_binary))
    page = browser.new_context.new_page

    page.evaluate("navigator.hardwareConcurrency").should eq(JSON::Any.new(3_i64))
  ensure
    browser.try &.close
  end

  it "sends the requests of a context through its proxy" do
    binary = camoufox_binary
    proxy = ForwardProxy.new
    config = Crystalfaux::Fingerprint::Config.for(os: :mac, screen: Crystalfaux::Fingerprint::Screen.new(1440, 900),
      user_agent: USER_AGENT)
    browser = Crystalfaux::Browser.launch(config: config,
      options: Crystalfaux::Launcher::Options.new(executable: binary))
    page = browser.new_context(proxy: Crystalfaux::Proxy.new("127.0.0.1", proxy.port)).new_page

    page.goto("http://crystalfaux.test/page")

    page.title.should eq("via proxy crystalfaux.test")
    receive_within(proxy.requests, 5.seconds).should eq({"http://crystalfaux.test/page", USER_AGENT})
  ensure
    browser.try &.close
    proxy.try &.close
  end

  it "sends every request through the browser proxy" do
    binary = camoufox_binary
    proxy = ForwardProxy.new
    browser = Crystalfaux::Browser.launch(Crystalfaux::Launcher::Options.new(executable: binary),
      proxy: Crystalfaux::Proxy.new("127.0.0.1", proxy.port))
    page = browser.new_context.new_page

    page.goto("http://browser-proxy.test/")

    page.title.should eq("via proxy browser-proxy.test")
    receive_within(proxy.requests, 5.seconds)[0].should eq("http://browser-proxy.test/")
  ensure
    browser.try &.close
    proxy.try &.close
  end
end

describe "the committed macOS desktop fingerprint", tags: "browser" do
  it "reports its user agent and screen size, and no webdriver" do
    dir = Path[__DIR__, "..", "..", "examples", "fingerprints"]
    config = Crystalfaux::Fingerprint::Config.from_json(File.read(dir / "macos-desktop.json"))
    prefs = JSON.parse(File.read(dir / "macos-desktop.prefs.json")).as_h
    browser = Crystalfaux::Browser.launch(config: config, prefs: prefs,
      options: Crystalfaux::Launcher::Options.new(executable: camoufox_binary))
    page = browser.new_context.new_page
    page.goto("data:text/html,<title>fingerprint</title>")

    page.evaluate("navigator.userAgent").should eq(config["navigator.userAgent"])
    page.evaluate("[screen.width, screen.height]").should eq(JSON::Any.new([config["screen.width"], config["screen.height"]]))
    page.evaluate("navigator.webdriver").should eq(JSON::Any.new(false))
  ensure
    browser.try &.close
  end
end
