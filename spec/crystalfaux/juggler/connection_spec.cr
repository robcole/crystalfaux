require "../../spec_helper"

# Pending replies are internal state with no public view; this spec-only
# reader lets the specs prove a failed call releases its entry.
class Crystalfaux::Juggler::Connection
  def pending_count_for_spec : Int32
    @lock.synchronize { @pending.size }
  end
end

describe Crystalfaux::Juggler::Connection do
  describe "#call" do
    it "sends the request and returns the result of the matching reply" do
      connection, peer = connected_pair
      outcome = async { connection.call("Page.navigate", {frameId: "f1", url: "about:blank"}, "s1") }

      request = peer.request
      request["method"].should eq("Page.navigate")
      request["params"].should eq(JSON.parse(%({"frameId":"f1","url":"about:blank"})))
      request["sessionId"].should eq("s1")
      peer.reply(request["id"], {navigationId: "nav-1"}, "s1")

      receive_within(outcome).should eq(JSON.parse(%({"navigationId":"nav-1"})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "sends root-session requests without sessionId and with empty params" do
      connection, peer = connected_pair
      outcome = async { connection.call("Browser.getInfo") }

      request = peer.request
      request.as_h.has_key?("sessionId").should be_false
      request["params"].should eq(JSON.parse("{}"))
      peer.reply(request["id"], {version: "Firefox/152.0.4"})

      receive_within(outcome).should eq(JSON.parse(%({"version":"Firefox/152.0.4"})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "uses increasing ids and matches replies that arrive out of order" do
      connection, peer = connected_pair
      first = async { connection.call("Runtime.evaluate", {expression: "1"}) }
      first_request = peer.request
      second = async { connection.call("Runtime.evaluate", {expression: "2"}) }
      second_request = peer.request

      second_request["id"].as_i64.should be > first_request["id"].as_i64
      peer.reply(second_request["id"], {value: 2})
      peer.reply(first_request["id"], {value: 1})

      receive_within(first).should eq(JSON.parse(%({"value":1})))
      receive_within(second).should eq(JSON.parse(%({"value":2})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "raises ProtocolError when the reply carries an error" do
      connection, peer = connected_pair
      outcome = async { connection.call("Browser.setDefaultViewport") }

      peer.reply_error(peer.request["id"], "Invalid parameters")

      error = receive_within(outcome).should be_a(Crystalfaux::ProtocolError)
      error.method.should eq("Browser.setDefaultViewport")
      error.message.should eq("Protocol error (Browser.setDefaultViewport): Invalid parameters")
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "raises TimeoutError when no reply arrives in time and ignores a late reply" do
      connection, peer = connected_pair
      slow = async { connection.call("Browser.close", timeout: 20.milliseconds) }
      slow_request = peer.request

      error = receive_within(slow).should be_a(Crystalfaux::TimeoutError)
      error.message.should eq("Browser.close timed out after 00:00:00.020000000")

      peer.reply(slow_request["id"], {late: true})
      next_call = async { connection.call("Browser.getInfo") }
      peer.reply(peer.request["id"], {on_time: true})
      receive_within(next_call).should eq(JSON.parse(%({"on_time":true})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "releases the request when its params cannot be serialized" do
      connection, peer = connected_pair

      expect_raises(JSON::Error) { connection.call("Page.method", {value: Float64::NAN}) }

      connection.pending_count_for_spec.should eq(0)
      outcome = async { connection.call("Browser.getInfo") }
      request = peer.request
      request["method"].should eq("Browser.getInfo")
      peer.reply(request["id"], {ok: true})
      receive_within(outcome).should eq(JSON.parse(%({"ok":true})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "times out a queued call without sending it and stays usable" do
      connection, peer = connected_pair
      # Blocks the writer until the peer reads, which it does not do yet.
      blocked = async { connection.call("Runtime.evaluate", {expression: "x" * 2_000_000}, timeout: 5.seconds) }
      Fiber.yield
      queued = async { connection.call("Browser.getInfo", timeout: 30.milliseconds) }

      receive_within(queued).should be_a(Crystalfaux::TimeoutError)
      connection.closed?.should be_false

      blocked_request = peer.request
      blocked_request["method"].should eq("Runtime.evaluate")
      peer.reply(blocked_request["id"], {value: 1})
      receive_within(blocked).should eq(JSON.parse(%({"value":1})))

      later = async { connection.call("Browser.newPage") }
      later_request = peer.request
      later_request["method"].should eq("Browser.newPage")
      peer.reply(later_request["id"], {targetId: "t1"})
      receive_within(later).should eq(JSON.parse(%({"targetId":"t1"})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "raises ConnectionClosed after the connection is closed" do
      connection, peer = connected_pair
      connection.close

      expect_raises(Crystalfaux::ConnectionClosed) { connection.call("Browser.getInfo") }
    ensure
      connection.try &.close
      peer.try &.close
    end
  end

  describe "#on" do
    it "routes events by session and method" do
      connection, peer = connected_pair
      root = Channel(JSON::Any).new(10)
      page = Channel(JSON::Any).new(10)
      connection.on("Browser.attachedToTarget") { |params| root.send(params) }
      connection.on("Page.eventFired", "s1") { |params| page.send(params) }

      peer.event("Page.eventFired", {name: "load"}, "other-session")
      peer.event("Page.frameAttached", {frameId: "f1"}, "s1")
      peer.event("Page.eventFired", {name: "load"}, "s1")
      peer.event("Browser.attachedToTarget", {sessionId: "s1"})

      receive_within(page).should eq(JSON.parse(%({"name":"load"})))
      receive_within(root).should eq(JSON.parse(%({"sessionId":"s1"})))
      quiet?(page).should be_true
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "handles events that arrive before a reply before the call returns" do
      connection, peer = connected_pair
      attached = [] of String
      connection.on("Browser.attachedToTarget") { |params| attached << params["sessionId"].as_s }
      outcome = async { connection.call("Browser.newPage", {browserContextId: "c1"}) }

      request = peer.request
      peer.event("Browser.attachedToTarget", {sessionId: "s1"})
      peer.reply(request["id"], {targetId: "t1"})

      receive_within(outcome)
      attached.should eq(["s1"])
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "keeps dispatching after a handler raises" do
      connection, peer = connected_pair
      names = Channel(String).new(10)
      connection.on("Page.eventFired", "s1") do |params|
        name = params["name"].as_s
        raise "handler failed" if name == "bad"
        names.send(name)
      end

      peer.event("Page.eventFired", {name: "bad"}, "s1")
      peer.event("Page.eventFired", {name: "load"}, "s1")

      receive_within(names).should eq("load")
    ensure
      connection.try &.close
      peer.try &.close
    end
  end

  describe "#off" do
    it "stops delivering events to the removed handler" do
      connection, peer = connected_pair
      names = Channel(String).new(10)
      subscription = connection.on("Page.eventFired", "s1") { |params| names.send(params["name"].as_s) }
      connection.on("Page.eventFired", "s1") { |_params| names.send("kept") }

      connection.off(subscription)
      peer.event("Page.eventFired", {name: "load"}, "s1")

      receive_within(names).should eq("kept")
      quiet?(names).should be_true
    ensure
      connection.try &.close
      peer.try &.close
    end
  end

  describe "disconnect" do
    it "fails every pending call with ConnectionClosed at end of stream" do
      connection, peer = connected_pair
      first = async { connection.call("Browser.getInfo") }
      peer.request
      second = async { connection.call("Page.navigate", nil, "s1") }
      peer.request

      peer.close

      receive_within(first).should be_a(Crystalfaux::ConnectionClosed)
      receive_within(second).should be_a(Crystalfaux::ConnectionClosed)
      connection.closed?.should be_true
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "fails every pending call with ConnectionClosed when closed locally" do
      connection, peer = connected_pair
      outcome = async { connection.call("Browser.getInfo") }
      peer.request

      connection.close

      receive_within(outcome).should be_a(Crystalfaux::ConnectionClosed)
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "skips a frame that is not valid JSON and keeps reading" do
      connection, peer = connected_pair
      outcome = async { connection.call("Browser.getInfo") }
      request = peer.request

      peer.raw("not json")
      peer.reply(request["id"], {ok: true})

      receive_within(outcome).should eq(JSON.parse(%({"ok":true})))
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "times out a write the peer never reads and fails the call queued behind it" do
      connection, peer = connected_pair
      # Far larger than a pipe buffer, so the write blocks while the peer is
      # open but not reading.
      blocked = async { connection.call("Runtime.evaluate", {expression: "x" * 2_000_000}, timeout: 50.milliseconds) }
      Fiber.yield
      queued = async { connection.call("Browser.getInfo", timeout: 5.seconds) }

      receive_within(blocked).should be_a(Crystalfaux::TimeoutError)
      receive_within(queued).should be_a(Crystalfaux::ConnectionClosed)
      connection.closed?.should be_true
    ensure
      connection.try &.close
      peer.try &.close
    end

    it "fails every pending call when the request pipe breaks" do
      request_reader, request_writer = IO.pipe
      reply_reader, reply_writer = IO.pipe
      io = IO::Stapled.new(reply_reader, request_writer, sync_close: true)
      connection = Crystalfaux::Juggler::Connection.new(Crystalfaux::Juggler::Transport.new(io))
      pending = async { connection.call("Browser.getInfo") }
      request_reader.gets('\0').should_not be_nil

      # The browser closes its request fd but keeps its reply fd open.
      request_reader.close
      failed = async { connection.call("Browser.newPage") }

      receive_within(failed).should be_a(Crystalfaux::ConnectionClosed)
      receive_within(pending).should be_a(Crystalfaux::ConnectionClosed)
      connection.closed?.should be_true
    ensure
      connection.try &.close
      request_reader.try &.close
      reply_writer.try &.close
    end
  end
end
