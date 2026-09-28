# Plays the browser side of an in-process Juggler pipe: reads the requests a
# `Crystalfaux::Juggler::Connection` sends and writes replies and events.
class JugglerPeer
  getter io : IO

  def initialize(@io : IO)
    @transport = Crystalfaux::Juggler::Transport.new(@io)
  end

  # Returns the next request, or raises when none arrives in time.
  def request(timeout : Time::Span = 1.second) : JSON::Any
    frames = Channel(String?).new(1)
    spawn { frames.send(@transport.receive) }
    select
    when frame = frames.receive
      JSON.parse(frame || raise "peer reached end of stream")
    when timeout(timeout)
      raise "peer got no request within #{timeout}"
    end
  end

  # Blocks until the next request arrives; returns `nil` at end of stream.
  def receive? : JSON::Any?
    @transport.receive.try { |frame| JSON.parse(frame) }
  end

  def reply(id : JSON::Any, result, session_id : String? = nil) : Nil
    write({"id" => id, "result" => result, "sessionId" => session_id})
  end

  def reply_error(id : JSON::Any, message : String) : Nil
    write({"id" => id, "error" => {"message" => message, "data" => "stack"}})
  end

  def event(method : String, params, session_id : String? = nil) : Nil
    write({"method" => method, "params" => params, "sessionId" => session_id})
  end

  def raw(frame : String) : Nil
    @transport.send(frame)
  end

  def close : Nil
    @transport.close
  end

  private def write(message : Hash) : Nil
    @transport.send(message.compact.to_json)
  end
end

# Builds a connection wired to a peer over an in-process `IO::Stapled` pair.
def connected_pair : {Crystalfaux::Juggler::Connection, JugglerPeer}
  client, server = IO::Stapled.pipe
  transport = Crystalfaux::Juggler::Transport.new(client)
  {Crystalfaux::Juggler::Connection.new(transport), JugglerPeer.new(server)}
end

# Runs a blocking call in a fiber. Receive from the channel to get its result,
# or the exception it raised.
def async(&block : -> JSON::Any) : Channel(JSON::Any | Exception)
  outcome = Channel(JSON::Any | Exception).new(1)
  spawn do
    outcome.send(block.call)
  rescue ex
    outcome.send(ex)
  end
  outcome
end

# Returns true when nothing arrives on the channel within the span.
def quiet?(channel : Channel, span : Time::Span = 20.milliseconds) : Bool
  select
  when channel.receive
    false
  when timeout(span)
    true
  end
end

# Receives from the channel, or raises so a regression fails instead of hanging.
def receive_within(channel : Channel(T), span : Time::Span = 1.second) : T forall T
  select
  when value = channel.receive
    value
  when timeout(span)
    raise "nothing received within #{span}"
  end
end
