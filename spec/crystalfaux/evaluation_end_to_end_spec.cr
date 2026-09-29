require "../spec_helper"
require "http/server"

# Serves a page whose script sets `window.marker = 42` and that holds one
# iframe whose script sets `window.childMarker = 7`.
private class WorldsServer
  getter base_url : String

  def initialize
    @server = HTTP::Server.new do |context|
      context.response.content_type = "text/html"
      case context.request.path
      when "/"
        context.response.print %(<!DOCTYPE html><title>worlds</title><script>window.marker = 42</script><iframe src="/child"></iframe>)
      when "/child"
        context.response.print %(<!DOCTYPE html><script>window.childMarker = 7</script><p>child</p>)
      else
        context.response.status = :not_found
      end
    end
    address = @server.bind_tcp("127.0.0.1", 0)
    @base_url = "http://127.0.0.1:#{address.port}"
    spawn(name: "worlds-server") { @server.listen }
  end

  def close : Nil
    @server.close
  end
end

private def launch(binary : String, config : Hash(String, JSON::Any) = {} of String => JSON::Any) : Crystalfaux::Browser
  Crystalfaux::Browser.launch(Crystalfaux::Launcher::Options.new(executable: binary, config: config))
end

private def open_worlds_page(browser : Crystalfaux::Browser, server : WorldsServer) : {Crystalfaux::Page, Crystalfaux::Frame}
  page = browser.new_context.new_page
  page.goto("#{server.base_url}/")
  child = page.main_frame.children.first
  {page, child}
end

describe "Evaluation worlds", tags: "browser" do
  it "keeps page globals out of the isolated world in both frames" do
    binary = camoufox_binary
    server = WorldsServer.new
    browser = launch(binary)
    page, child = open_worlds_page(browser, server)

    page.evaluate("document.title").should eq(JSON::Any.new("worlds"))
    page.evaluate("window.marker").should eq(JSON::Any.new(nil))
    child.evaluate("document.body.textContent").should eq(JSON::Any.new("child"))
    child.evaluate("window.childMarker").should eq(JSON::Any.new(nil))
    # The main world needs allowMainWorld in the launch config.
    expect_raises(Crystalfaux::EvaluationError, /disabled/) { page.evaluate("window.marker", world: :main) }
  ensure
    browser.try &.close
    server.try &.close
  end

  it "reads page globals in the main world of both frames when allowMainWorld is set" do
    binary = camoufox_binary
    server = WorldsServer.new
    browser = launch(binary, {"allowMainWorld" => JSON::Any.new(true)})
    page, child = open_worlds_page(browser, server)

    page.evaluate("window.marker", world: :main).should eq(JSON::Any.new(42_i64))
    child.evaluate("window.childMarker", world: :main).should eq(JSON::Any.new(7_i64))
    page.evaluate("window.marker").should eq(JSON::Any.new(nil))
    page.evaluate("({a: {b: [1, undefined, null]}, d: new Date(0)})", world: :main)
      .should eq(JSON.parse(%({"a":{"b":[1,null,null]},"d":"1970-01-01T00:00:00.000Z"})))
    page.evaluate("Promise.resolve(-0)", world: :main).as_f.sign_bit.should eq(-1)
    nested = page.evaluate("[NaN, Infinity, -Infinity, -0]", world: :main).as_a.map(&.as_f)
    nested[0].nan?.should be_true
    nested[1..2].should eq([Float64::INFINITY, -Float64::INFINITY])
    nested[3].sign_bit.should eq(-1)
    # A symbol or a function becomes nil in place; the object keeps its keys.
    page.evaluate("({a: 1, s: Symbol('s'), f() {}})", world: :main).should eq(JSON.parse(%({"a":1,"s":null,"f":null})))
    child.evaluate("({a: 1, f: () => 1})", world: :main).should eq(JSON.parse(%({"a":1,"f":null})))
    page.evaluate("[1, Symbol('s'), () => 1]", world: :main).should eq(JSON.parse("[1,null,null]"))
    expect_raises(Crystalfaux::EvaluationError, /cycle/) do
      page.evaluate("(() => { const a = {}; a.a = a; return a })()", world: :main)
    end
    error = expect_raises(Crystalfaux::EvaluationError, "main boom") do
      page.evaluate("throw new Error('main boom')", world: :main)
    end
    error.stack.should_not be_nil

    # A navigation interrupts a main-world evaluation too.
    outcome = async { page.evaluate("new Promise(() => {})", world: :main, timeout: 10.seconds) }
    sleep 100.milliseconds
    page.goto("#{server.base_url}/?again")
    receive_within(outcome, 5.seconds).should be_a(Crystalfaux::ExecutionContextDestroyed)
  ensure
    browser.try &.close
    server.try &.close
  end

  it "defines the values that the isolated world returns" do
    binary = camoufox_binary
    server = WorldsServer.new
    browser = launch(binary)
    page, _ = open_worlds_page(browser, server)

    page.evaluate("undefined").should eq(JSON::Any.new(nil))
    page.evaluate("null").should eq(JSON::Any.new(nil))
    page.evaluate("NaN").as_f.nan?.should be_true
    page.evaluate("Infinity").should eq(JSON::Any.new(Float64::INFINITY))
    page.evaluate("-0").as_f.sign_bit.should eq(-1)
    page.evaluate("({a: {b: [1, undefined, null]}, u: undefined})").should eq(JSON.parse(%({"a":{"b":[1,null,null]}})))
    page.evaluate("new Date(0)").should eq(JSON.parse("{}"))
    page.evaluate("new Date(0).toISOString()").should eq(JSON::Any.new("1970-01-01T00:00:00.000Z"))
    page.evaluate("() => 1").should eq(JSON::Any.new(nil))
    # Nested values follow JSON.stringify: special numbers become null and
    # -0 becomes 0, functions leave objects and become null in arrays, and a
    # symbol anywhere makes the whole result nil.
    page.evaluate("[NaN, Infinity, -Infinity, -0]").should eq(JSON.parse("[null,null,null,0]"))
    page.evaluate("({n: NaN, z: -0})").should eq(JSON.parse(%({"n":null,"z":0})))
    page.evaluate("({a: 1, f() {}})").should eq(JSON.parse(%({"a":1})))
    page.evaluate("[1, () => 1]").should eq(JSON.parse("[1,null]"))
    page.evaluate("({a: 1, s: Symbol('s')})").should eq(JSON::Any.new(nil))
    page.evaluate("[1, Symbol('s')]").should eq(JSON::Any.new(nil))
    page.evaluate("new Promise(resolve => setTimeout(() => resolve('later'), 10))").should eq(JSON::Any.new("later"))

    error = expect_raises(Crystalfaux::EvaluationError, "rejected") { page.evaluate("Promise.reject(new Error('rejected'))") }
    error.stack.should_not be_nil
    expect_raises(Crystalfaux::EvaluationError, "\"text\"") { page.evaluate("throw 'text'") }
    expect_raises(Crystalfaux::EvaluationError, /serializable/) { page.evaluate("(() => { const a = {}; a.a = a; return a })()") }
    expect_raises(Crystalfaux::EvaluationError, /serializ/) { page.evaluate("10n") }
  ensure
    browser.try &.close
    server.try &.close
  end

  it "raises ExecutionContextDestroyed for an evaluation that a navigation interrupts" do
    binary = camoufox_binary
    server = WorldsServer.new
    browser = launch(binary)
    page, child = open_worlds_page(browser, server)
    outcome = async { page.evaluate("new Promise(() => {})", timeout: 10.seconds) }
    sleep 100.milliseconds

    page.goto("#{server.base_url}/?again")

    receive_within(outcome, 5.seconds).should be_a(Crystalfaux::ExecutionContextDestroyed)
    # The old iframe was replaced with the document.
    expect_raises(Crystalfaux::ExecutionContextDestroyed) { child.evaluate("1") }
    page.evaluate("document.title").should eq(JSON::Any.new("worlds"))
    page.main_frame.children.first.evaluate("document.body.textContent").should eq(JSON::Any.new("child"))
  ensure
    browser.try &.close
    server.try &.close
  end

  # Pins Camoufox behaviour that `Frame#evaluate` documents: the isolated
  # world does not settle a promise that a page API made, but does settle
  # one that the script made around it. A Camoufox change makes this fail.
  it "settles a page-API promise in the isolated world only when the script wraps it" do
    binary = camoufox_binary
    server = WorldsServer.new
    browser = launch(binary, {"allowMainWorld" => JSON::Any.new(true)})
    page, _ = open_worlds_page(browser, server)
    fetch_child = "fetch('/child').then(r => r.status)"

    expect_raises(Crystalfaux::TimeoutError) { page.evaluate(fetch_child, timeout: 1.second) }
    page.evaluate("new Promise((resolve, reject) => #{fetch_child}.then(resolve, reject))")
      .should eq(JSON::Any.new(200_i64))
    page.evaluate(fetch_child, world: :main).should eq(JSON::Any.new(200_i64))
  ensure
    browser.try &.close
    server.try &.close
  end
end
