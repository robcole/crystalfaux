require "../../spec_helper"

describe Crystalfaux::Juggler::Transport do
  it "terminates each sent frame with a NUL byte" do
    client, server = IO::Stapled.pipe
    transport = Crystalfaux::Juggler::Transport.new(client)

    transport.send(%({"id":1}))
    transport.send(%({"id":2}))

    server.read_string(18).should eq(%({"id":1}\0{"id":2}\0))
  ensure
    client.try &.close
    server.try &.close
  end

  it "receives complete frames split on NUL bytes" do
    client, server = IO::Stapled.pipe
    transport = Crystalfaux::Juggler::Transport.new(client)

    server << %({"a":"line\\nbreak"}\0{"b") << %(:2}\0)
    server.flush

    transport.receive.should eq(%({"a":"line\\nbreak"}))
    transport.receive.should eq(%({"b":2}))
  ensure
    client.try &.close
    server.try &.close
  end

  it "returns nil at end of stream" do
    client, server = IO::Stapled.pipe
    transport = Crystalfaux::Juggler::Transport.new(client)

    server << %({"id":1}\0)
    server.close

    transport.receive.should eq(%({"id":1}))
    transport.receive.should be_nil
  ensure
    client.try &.close
  end

  it "drops a truncated frame at end of stream" do
    client, server = IO::Stapled.pipe
    transport = Crystalfaux::Juggler::Transport.new(client)

    server << %({"id":1)
    server.close

    transport.receive.should be_nil
  ensure
    client.try &.close
  end

  it "returns nil after it is closed" do
    client, server = IO::Stapled.pipe
    transport = Crystalfaux::Juggler::Transport.new(client)

    transport.close

    transport.closed?.should be_true
    transport.receive.should be_nil
  ensure
    server.try &.close
  end

  it "raises ConnectionClosed when sending after close" do
    client, server = IO::Stapled.pipe
    transport = Crystalfaux::Juggler::Transport.new(client)
    transport.close

    expect_raises(Crystalfaux::ConnectionClosed) { transport.send("{}") }
  ensure
    server.try &.close
  end
end
