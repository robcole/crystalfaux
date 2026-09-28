require "../spec_helper"
require "http/server"

# Serves a page with an image, and records each request path with its
# `X-Crystalfaux` header.
private class SiteServer
  getter base_url : String
  @hits = Channel({String, String?}).new(64)

  def initialize
    @server = HTTP::Server.new do |context|
      @hits.send({context.request.path, context.request.headers["X-Crystalfaux"]?})
      case context.request.path
      when "/"
        context.response.content_type = "text/html"
        context.response.print %(<!DOCTYPE html><title>site</title><img src="/pixel.png">)
      when "/pixel.png"
        context.response.content_type = "image/png"
        context.response.print "not really a png"
      else
        context.response.status = :not_found
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @base_url = "http://127.0.0.1:#{address.port}"
    spawn(name: "site-server") { @server.listen }
  end

  # The requests received so far, except for the favicon, which the browser
  # may or may not fetch.
  def hits : Array({String, String?})
    hits = [] of {String, String?}
    loop do
      select
      when hit = @hits.receive
        hits << hit unless hit[0] == "/favicon.ico"
      else
        return hits
      end
    end
  end

  def close : Nil
    @server.close
  end
end

describe "network", tags: "browser" do
  it "blocks, fulfills, reads bodies, adds headers and keeps cookies against a real Camoufox" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
    site = SiteServer.new
    browser = Crystalfaux::Browser.launch(options)
    context = browser.new_context
    page = context.new_page
    context.block(types: [Crystalfaux::ResourceType::Image])
    context.extra_headers = HTTP::Headers{"X-Crystalfaux" => "yes"}
    page.on_request do |request|
      request.fulfill(body: "<title>routed</title>", content_type: "text/html") if request.url.ends_with?("/routed")
    end
    bodies = Channel({String, String}).new(8)
    page.on_response { |response| bodies.send({response.url, response.text}) }

    page.goto("#{site.base_url}/")

    page.title.should eq("site")
    receive_within(bodies, 5.seconds).should eq({"#{site.base_url}/", %(<!DOCTYPE html><title>site</title><img src="/pixel.png">)})
    page.evaluate("document.images[0].naturalWidth").should eq(JSON::Any.new(0_i64))
    site.hits.should eq([{"/", "yes"}])

    page.goto("#{site.base_url}/routed")

    page.title.should eq("routed")
    site.hits.should be_empty

    context.set_cookies([Crystalfaux::CookieOptions.new("flavour", "oat", url: "#{site.base_url}/")])
    context.cookies.map { |cookie| {cookie.name, cookie.value, cookie.domain} }.should eq([{"flavour", "oat", "127.0.0.1"}])
    page.evaluate("document.cookie").should eq(JSON::Any.new("flavour=oat"))
    context.clear_cookies
    context.cookies.should be_empty
  ensure
    browser.try &.close
    site.try &.close
  end
end
