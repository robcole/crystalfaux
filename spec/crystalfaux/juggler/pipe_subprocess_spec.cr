require "../../spec_helper"

# Runs the same fd 3 / fd 4 wrapper the launcher uses, with `cat` in place of
# the browser. By default every frame written to fd 3 comes back on fd 4.
private FD_WRAPPER = %(exec 3<&0 4>&1 </dev/null >&2; exec "$0" "$@")

private def spawn_cat(script : String = "exec cat <&3 >&4") : {Process, Crystalfaux::Juggler::Transport}
  process = Process.new("sh", ["-c", FD_WRAPPER, "sh", "-c", script],
    input: :pipe, output: :pipe, error: :inherit)
  # The transport owns both pipe ends; closing it closes fd 3 in the child.
  io = IO::Stapled.new(process.output, process.input, sync_close: true)
  {process, Crystalfaux::Juggler::Transport.new(io)}
end

describe "Juggler pipe through a subprocess" do
  it "round-trips frames, correlates ids and routes events, then ends at EOF" do
    process, transport = spawn_cat
    connection = Crystalfaux::Juggler::Connection.new(transport)
    events = Channel(JSON::Any).new(10)
    connection.on("Page.eventFired", "s1") { |params| events.send(params) }

    # cat echoes the request itself, which carries the same id and no result.
    connection.call("Browser.getInfo", {large: "x" * 100_000}).should eq(JSON::Any.new(nil))

    transport.send(%({"method":"Page.eventFired","params":{"name":"load"},"sessionId":"s1"}))
    receive_within(events).should eq(JSON.parse(%({"name":"load"})))

    connection.close
    process.wait.success?.should be_true
    connection.closed?.should be_true
  ensure
    process.try &.terminate unless process.try &.terminated?
  end

  it "fails a pending call when the child process dies" do
    # This child reads requests but never answers, and holds fd 4 open.
    process, transport = spawn_cat("exec cat <&3 >/dev/null")
    connection = Crystalfaux::Juggler::Connection.new(transport)
    outcome = async { connection.call("Browser.close") }
    Fiber.yield

    process.signal(Signal::KILL)
    process.wait

    receive_within(outcome).should be_a(Crystalfaux::ConnectionClosed)
  ensure
    connection.try &.close
  end
end
