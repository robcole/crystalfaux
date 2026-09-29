require "../spec_helper"
require "http/server"

# Serves the documents of the navigation specs. `/held` has an image that
# the server holds until `#release_image` is called, so the page's `load`
# waits for it.
private class NavigationServer
  getter base_url : String
  @image_gate = Channel(Nil).new(1)

  def initialize
    @server = HTTP::Server.new do |context|
      response = context.response
      case context.request.path
      when "/ok"
        response.content_type = "text/html"
        response.print "<title>ok</title>"
      when "/redirect"
        response.status = :found
        response.headers["Location"] = "/ok"
      when "/body-404"
        response.status = :not_found
        response.content_type = "text/html"
        response.print "<title>missing</title>"
      when "/empty-404" then response.status = :not_found
      when "/empty-403" then response.status = :forbidden
      when "/held"
        response.content_type = "text/html"
        response.print %(<title>held</title><img src="/held.png">)
      when "/held.png"
        @image_gate.receive
        response.content_type = "image/png"
        response.print "not really a png"
      else
        response.status = :not_found
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @base_url = "http://127.0.0.1:#{address.port}"
    spawn(name: "navigation-server") { @server.listen }
  end

  def release_image : Nil
    @image_gate.send(nil)
  end

  def close : Nil
    @server.close
  end
end

private def with_navigation_page(& : Crystalfaux::Page, NavigationServer ->) : Nil
  options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
  server = NavigationServer.new
  browser = Crystalfaux::Browser.launch(options)
  begin
    yield browser.new_context.new_page, server
  ensure
    browser.close
    server.close
  end
end

describe "Page#goto", tags: "browser" do
  it "returns the document's response for each status against a real Camoufox" do
    with_navigation_page do |page, server|
      ok = page.goto("#{server.base_url}/ok").should_not(be_nil)
      ok.status.should eq(200)
      ok.url.should eq("#{server.base_url}/ok")

      redirected = page.goto("#{server.base_url}/redirect").should_not(be_nil)
      redirected.status.should eq(200)
      redirected.url.should eq("#{server.base_url}/ok")

      missing = page.goto("#{server.base_url}/body-404").should_not(be_nil)
      missing.status.should eq(404)
      page.title.should eq("missing")

      page.goto("about:blank").should be_nil
      page.goto("data:text/html,<title>data</title>").should be_nil
    end
  end

  it "raises NavigationError with the response for an empty error response" do
    with_navigation_page do |page, server|
      {"/empty-404" => 404, "/empty-403" => 403}.each do |path, status|
        error = expect_raises(Crystalfaux::NavigationError, /NS_ERROR_NET_EMPTY_RESPONSE/) do
          page.goto("#{server.base_url}#{path}")
        end
        response = error.response.should_not(be_nil)
        response.status.should eq(status)
        response.url.should eq("#{server.base_url}#{path}")
      end
    end
  end

  it "returns before the load of a slow subresource with :dom_content_loaded and :commit" do
    with_navigation_page do |page, server|
      page.goto("#{server.base_url}/held", wait_until: :dom_content_loaded).try(&.status).should eq(200)
      page.evaluate("document.readyState").should_not eq(JSON::Any.new("complete"))
      server.release_image

      page.goto("#{server.base_url}/ok", wait_until: :commit).try(&.status).should eq(200)
      page.url.should eq("#{server.base_url}/ok")
    end
  end

  it "waits for the load of a slow subresource by default" do
    with_navigation_page do |page, server|
      released = Channel(Nil).new(1)
      spawn do
        sleep 300.milliseconds
        server.release_image
        released.send(nil)
      end

      page.goto("#{server.base_url}/held").try(&.status).should eq(200)

      select
      when released.receive
      else
        fail "goto returned before the image was served"
      end
      page.evaluate("document.readyState").should eq(JSON::Any.new("complete"))
    end
  end
end
