require "../spec_helper"

# Launches `Crystalfaux::Browser`s on `ScriptedBrowser` fakes for a pool,
# and keeps each fake by launch number.
class FakeLaunches
  getter fakes = [] of ScriptedBrowser
  getter browsers = [] of Crystalfaux::Browser
  getter numbers = [] of Int32

  def launch(number : Int32) : Crystalfaux::Browser
    browser, fake = scripted_browser
    @numbers << number
    @fakes << fake
    @browsers << browser
    browser
  end

  def close : Nil
    @fakes.each(&.close)
  end
end

# Wraps the browser side of a fake pipe and holds the `Browser.close`
# frame until `#open`, so a spec can keep a browser shutdown in progress.
class CloseGate < IO
  @opened = Channel(Nil).new

  def initialize(@io : IO)
  end

  def read(slice : Bytes) : Int32
    @io.read(slice)
  end

  def write(slice : Bytes) : Nil
    if String.new(slice).includes?(%("method":"Browser.close"))
      select
      when @opened.receive?
      when timeout(5.seconds)
        raise "gate never opened"
      end
    end
    @io.write(slice)
  end

  def flush : Nil
    @io.flush
  end

  def close : Nil
    @io.close
  end

  def closed? : Bool
    @io.closed?
  end

  # Lets the held `Browser.close` frame, and every later one, through.
  def open : Nil
    @opened.close
  end
end

# Connects a `Crystalfaux::Browser` to a `ScriptedBrowser` over a pipe whose
# `Browser.close` frame waits for the returned gate.
def gated_scripted_browser : {Crystalfaux::Browser, ScriptedBrowser, CloseGate}
  client, server = IO::Stapled.pipe
  gate = CloseGate.new(client)
  connection = Crystalfaux::Juggler::Connection.new(Crystalfaux::Juggler::Transport.new(gate))
  fake = ScriptedBrowser.new(JugglerPeer.new(server))
  {Crystalfaux::Browser.connect(connection), fake, gate}
end

# Polls *condition* until it holds, or raises so a regression fails instead
# of hanging.
def wait_until(timeout : Time::Span = 1.second, & : -> Bool) : Nil
  deadline = Time.instant + timeout
  until yield
    raise "condition not met within #{timeout}" if Time.instant > deadline
    sleep 5.milliseconds
  end
end

def fake_pool(launches : FakeLaunches, size : Int32 = 1, pages_per_browser : Int32 = 10) : Crystalfaux::Pool
  Crystalfaux::Pool.new(size: size, pages_per_browser: pages_per_browser) { |number| launches.launch(number) }
end

describe Crystalfaux::Pool do
  it "rejects a size or page count below one" do
    expect_raises(ArgumentError) { Crystalfaux::Pool.new(size: 0, pages_per_browser: 1) { raise "unused" } }
    expect_raises(ArgumentError) { Crystalfaux::Pool.new(size: 1, pages_per_browser: 0) { raise "unused" } }
  end

  describe "#with_page" do
    it "gives the block a fresh page in a fresh context, then closes the page before the context" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)

      title = pool.with_page do |page|
        page.goto(ProbeScript::DATA_URL)
        page.context.browser.contexts.should eq([page.context])
        "done"
      end

      title.should eq("done")
      fake = launches.fakes.first
      fake.request("Page.close")
      fake.request("Browser.removeBrowserContext")
      launches.browsers.first.contexts.should be_empty
      launches.browsers.first.closed?.should be_false
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "launches browsers lazily and passes each launch a new number" do
      launches = FakeLaunches.new
      pool = fake_pool(launches, size: 2)

      launches.numbers.should be_empty
      pool.with_page { }
      launches.numbers.should eq([0])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "replaces a browser after it served pages_per_browser pages" do
      launches = FakeLaunches.new
      pool = fake_pool(launches, pages_per_browser: 2)

      2.times { pool.with_page { } }

      launches.numbers.should eq([0])
      launches.browsers.first.closed?.should be_true
      launches.fakes.first.request("Browser.close")

      pool.with_page { }
      launches.numbers.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "replaces a browser whose page crashed, and does not retry the block" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)
      runs = 0

      expect_raises(Crystalfaux::PageCrashed) do
        pool.with_page do |page|
          runs += 1
          launches.fakes.first.event("Page.crashed", {} of String => String)
          page.wait_for_events_for_spec
          page.evaluate("1")
        end
      end

      runs.should eq(1)
      launches.browsers.first.closed?.should be_true
      pool.with_page { }
      launches.numbers.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "replaces a browser whose pipe closed while it was idle" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)
      pool.with_page { }
      browser = launches.browsers.first

      launches.fakes.first.close
      wait_until { browser.closed? }

      pool.with_page(&.goto(ProbeScript::DATA_URL))
      launches.numbers.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "raises the connection error to a block whose browser dies mid-block, then replaces it" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)

      expect_raises(Crystalfaux::ConnectionClosed) do
        pool.with_page do |page|
          launches.fakes.first.close
          wait_until { page.closed? }
          page.evaluate("1")
        end
      end

      pool.with_page { }
      launches.numbers.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "raises a failed launch to the caller and launches again on the next checkout" do
      launches = FakeLaunches.new
      failures = 1
      pool = Crystalfaux::Pool.new(size: 1, pages_per_browser: 5) do |number|
        if failures > 0
          failures -= 1
          raise Crystalfaux::LaunchError.new("no browser")
        end
        launches.launch(number)
      end

      expect_raises(Crystalfaux::LaunchError, "no browser") { pool.with_page { } }
      pool.with_page { }
      launches.numbers.should eq([1])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "runs up to size blocks at once, each on its own browser, and queues the rest" do
      launches = FakeLaunches.new
      pool = fake_pool(launches, size: 2)
      entered = Channel(Crystalfaux::Browser).new(3)
      release = Channel(Nil).new
      done = Channel(Nil).new(3)

      3.times do
        spawn do
          pool.with_page do |page|
            entered.send(page.context.browser)
            release.receive
          end
          done.send(nil)
        end
      end

      first = receive_within(entered)
      second = receive_within(entered)
      first.should_not be(second)
      quiet?(entered, 100.milliseconds).should be_true

      release.send(nil)
      third = receive_within(entered)
      [first, second].should contain(third)
      2.times { release.send(nil) }
      3.times { receive_within(done) }
      launches.numbers.sort.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end
  end

  describe "#with_page cleanup" do
    it "raises the block's error after closing its page and context, and reuses the browser" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)

      expect_raises(Exception, "block failed") { pool.with_page { raise "block failed" } }

      fake = launches.fakes.first
      fake.request("Page.close")
      fake.request("Browser.removeBrowserContext")
      pool.with_page { }
      launches.numbers.should eq([0])
      launches.browsers.first.closed?.should be_false
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "raises a failed page creation, removes its context, and replaces the browser" do
      launches = FakeLaunches.new
      pool = Crystalfaux::Pool.new(size: 1, pages_per_browser: 5) do |number|
        launches.launch(number).tap do
          if number == 0
            launches.fakes.last.on("Browser.newPage") { [json_frame({id: 0, error: {message: "no page"}})] }
          end
        end
      end
      runs = 0

      expect_raises(Crystalfaux::ProtocolError, /no page/) { pool.with_page { runs += 1 } }

      runs.should eq(0)
      launches.fakes.first.request("Browser.removeBrowserContext")
      launches.browsers.first.closed?.should be_true
      pool.with_page { runs += 1 }
      runs.should eq(1)
      launches.numbers.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "returns the block's value when closing the page fails, and replaces the browser" do
      launches = FakeLaunches.new
      pool = Crystalfaux::Pool.new(size: 1, pages_per_browser: 5) do |number|
        launches.launch(number).tap do
          if number == 0
            launches.fakes.last.on("Page.close") { [json_frame({id: 0, error: {message: "cannot close"}})] }
          end
        end
      end

      pool.with_page { "value" }.should eq("value")

      launches.browsers.first.closed?.should be_true
      pool.with_page { }
      launches.numbers.should eq([0, 1])
    ensure
      pool.try &.close
      launches.try &.close
    end
  end

  describe "#close" do
    it "owns the shutdown of a browser whose call ends while close runs" do
      gates = [] of CloseGate
      fakes = [] of ScriptedBrowser
      browsers = [] of Crystalfaux::Browser
      pool = Crystalfaux::Pool.new(size: 2, pages_per_browser: 1) do
        browser, fake, gate = gated_scripted_browser
        gates << gate
        fakes << fake
        browsers << browser
        browser
      end
      entered = Channel(Nil).new(2)
      release_first = Channel(Nil).new
      done = Channel(Nil).new(2)
      spawn do
        pool.with_page { entered.send(nil); release_first.receive }
      ensure
        done.send(nil)
      end
      receive_within(entered)
      spawn do
        pool.with_page do
          entered.send(nil)
          wait_until { pool.closed? }
        end
      ensure
        done.send(nil)
      end
      receive_within(entered)
      first, second = browsers
      closed = Channel(Nil).new(1)
      spawn do
        pool.close
        closed.send(nil)
      end

      # Close is held in the first browser's shutdown. The second call ends
      # meanwhile and leaves its browser to close.
      receive_within(done)
      second.connection.closed?.should be_false
      gates[0].open
      quiet?(closed, 100.milliseconds).should be_true

      gates[1].open
      receive_within(closed)
      first.connection.closed?.should be_true
      second.connection.closed?.should be_true
      release_first.send(nil)
      receive_within(done)
    ensure
      gates.try &.each(&.open)
      pool.try &.close
      fakes.try &.each(&.close)
    end

    it "raises PoolError when the launch block closes its own pool, and keeps the pool open" do
      launches = FakeLaunches.new
      pools = [] of Crystalfaux::Pool
      pool = Crystalfaux::Pool.new(size: 1, pages_per_browser: 5) do |number|
        expect_raises(Crystalfaux::PoolError, /launch block/) { pools.first.close }
        launches.launch(number)
      end
      pools << pool
      outcome = Channel(Exception?).new(1)
      spawn do
        pool.with_page { }
        outcome.send(nil)
      rescue ex
        outcome.send(ex)
      end

      receive_within(outcome).should be_nil
      pool.closed?.should be_false
      pool.close
      launches.browsers.first.closed?.should be_true
    ensure
      # No `pool.close` here: after a regression the launch still waits in
      # its own close, and this close would wait for it forever.
      launches.try &.close
    end

    it "waits for a launch in progress, then closes the browser it returns" do
      launches = FakeLaunches.new
      started = Channel(Nil).new(1)
      finish = Channel(Nil).new
      pool = Crystalfaux::Pool.new(size: 1, pages_per_browser: 5) do |number|
        started.send(nil)
        finish.receive
        launches.launch(number)
      end
      checkout = Channel(Exception?).new(1)
      spawn do
        pool.with_page { }
        checkout.send(nil)
      rescue ex
        checkout.send(ex)
      end
      receive_within(started)
      closed = Channel(Nil).new(1)
      spawn do
        pool.close
        closed.send(nil)
      end

      quiet?(closed, 100.milliseconds).should be_true
      finish.send(nil)

      receive_within(closed)
      launches.browsers.first.closed?.should be_true
      launches.fakes.first.request("Browser.close")
      receive_within(checkout).should be_a(Crystalfaux::PoolClosed)
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "closes every browser and fails later checkouts" do
      launches = FakeLaunches.new
      pool = fake_pool(launches, size: 2)
      # Idle browsers queue in order, so two calls use both.
      2.times { pool.with_page { } }
      launches.numbers.should eq([0, 1])

      pool.close

      launches.fakes.each(&.request("Browser.close"))
      launches.browsers.each(&.closed?.should(be_true))
      expect_raises(Crystalfaux::PoolClosed) { pool.with_page { } }
      pool.close
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "closes a browser in use, so the running block fails and its browser is not reused" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)
      entered = Channel(Crystalfaux::Page).new(1)
      outcome = Channel(Exception?).new(1)
      spawn do
        pool.with_page do |page|
          entered.send(page)
          wait_until { page.closed? }
          page.evaluate("1")
        end
        outcome.send(nil)
      rescue ex
        outcome.send(ex)
      end
      page = receive_within(entered)

      pool.close

      receive_within(outcome).should be_a(Crystalfaux::ConnectionClosed)
      page.context.browser.closed?.should be_true
      expect_raises(Crystalfaux::PoolClosed) { pool.with_page { } }
      launches.numbers.should eq([0])
    ensure
      pool.try &.close
      launches.try &.close
    end

    it "wakes a caller that waits for a browser" do
      launches = FakeLaunches.new
      pool = fake_pool(launches)
      entered = Channel(Nil).new(1)
      waiter = Channel(Exception?).new(1)
      spawn { pool.with_page { entered.send(nil); sleep 1.second } }
      receive_within(entered)
      spawn do
        pool.with_page { }
        waiter.send(nil)
      rescue ex
        waiter.send(ex)
      end
      quiet?(waiter).should be_true

      pool.close

      receive_within(waiter).should be_a(Crystalfaux::PoolClosed)
    ensure
      pool.try &.close
      launches.try &.close
    end
  end
end
