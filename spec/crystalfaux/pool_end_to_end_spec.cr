require "../spec_helper"
require "http/server"

describe Crystalfaux::Pool, tags: "browser" do
  it "serves sequential pages, rotates browsers, and survives a killed browser" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary, headless: true)
    server = HTTP::Server.new do |context|
      context.response.content_type = "text/html"
      context.response.print %(<!DOCTYPE html><title>soak #{context.request.path}</title>)
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn(name: "soak-server") { server.listen }
    started = Time.instant
    browsers = [] of Crystalfaux::Browser
    pool = Crystalfaux::Pool.new(size: 2, pages_per_browser: 3) do
      Crystalfaux::Browser.launch(options).tap { |browser| browsers << browser }
    end
    titles = [] of String
    failures = [] of Crystalfaux::Error

    10.times do |call|
      pool.with_page do |page|
        if call == 3
          process = page.context.browser.process.should_not be_nil
          Process.signal(:kill, process.pid)
        end
        page.goto("http://127.0.0.1:#{address.port}/#{call}")
        titles << page.title
      end
    rescue ex : Crystalfaux::ConnectionClosed | Crystalfaux::PageClosed
      failures << ex
    end

    failures.size.should eq(1)
    expected = (0...10).reject(3).map { |call| "soak /#{call}" }
    titles.should eq(expected)
    # Calls alternate between the two slots. Slot 0 serves calls 0, 2, 4,
    # then is rotated; slot 1 serves 1 and 3, whose browser is killed.
    browsers.size.should eq(4)

    pool.close
    browsers.each do |browser|
      process = browser.process.should_not be_nil
      process.exited?.should be_true
      Dir.exists?(process.profile_dir).should be_false
    end
    (Time.instant - started).should be < 60.seconds
  ensure
    pool.try &.close
    server.try &.close
  end
end
