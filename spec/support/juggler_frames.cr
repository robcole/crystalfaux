# One Juggler frame as recorded in `spec/fixtures/juggler/*.frames`: one line
# per frame, `> ` for a frame the client sent and `< ` for a frame the
# browser sent, followed by the frame's JSON exactly as it crossed the pipe.
record JugglerFrame, sent : Bool, text : String do
  def self.parse(line : String) : self
    marker, text = line[0, 2], line[2..]
    raise "bad fixture line: #{line}" unless marker.in?("> ", "< ")
    new(marker == "> ", text)
  end

  def self.load(path : String) : Array(self)
    File.read_lines(path).reject(&.empty?).map { |line| parse(line) }
  end

  def json : JSON::Any
    JSON.parse(text)
  end

  def to_s(io : IO) : Nil
    io << (sent ? "> " : "< ") << text
  end
end

# Relays frames between a `Juggler::Connection` and a browser transport, and
# records every frame in order. Received frames also go to `#inbox`, so a
# driver can wait for events in the order they arrived; `#wait_until_sent`
# waits until a request has reached the browser.
#
# The relay starts two fibers. Each stops at end of stream on its side and
# then closes the other side's transport.
class RecordingRelay
  # The transport to build the `Juggler::Connection` on.
  getter transport : Crystalfaux::Juggler::Transport
  getter inbox = Channel(JSON::Any).new(4096)
  @sent = Channel(JSON::Any).new(4096)

  @frames = [] of JugglerFrame
  @lock = Sync::Mutex.new

  def initialize(browser : Crystalfaux::Juggler::Transport)
    client, relay_side = IO::Stapled.pipe
    @transport = Crystalfaux::Juggler::Transport.new(client)
    near = Crystalfaux::Juggler::Transport.new(relay_side)
    spawn { forward(near, browser, sent: true) }
    spawn { forward(browser, near, sent: false) }
  end

  def frames : Array(JugglerFrame)
    @lock.synchronize { @frames.dup }
  end

  # Returns the next received message that matches the block, skipping the
  # others, or raises after *timeout*.
  def wait_for(timeout : Time::Span = 30.seconds, & : JSON::Any -> Bool) : JSON::Any
    next_matching(inbox, timeout) { |message| yield message }
  end

  # Returns once the relay has passed a request for *method* to the browser.
  def wait_until_sent(method : String, timeout : Time::Span = 5.seconds) : Nil
    next_matching(@sent, timeout, &.["method"].==(method))
  end

  private def next_matching(channel : Channel(JSON::Any), timeout : Time::Span, & : JSON::Any -> Bool) : JSON::Any
    deadline = Time.instant + timeout
    loop do
      select
      when message = channel.receive
        return message if yield message
      when timeout({deadline - Time.instant, Time::Span.zero}.max)
        raise "no matching Juggler message within #{timeout}"
      end
    end
  end

  private def forward(from : Crystalfaux::Juggler::Transport, to : Crystalfaux::Juggler::Transport, sent : Bool) : Nil
    while frame = from.receive
      @lock.synchronize { @frames << JugglerFrame.new(sent, frame) }
      to.send(frame)
      (sent ? @sent : inbox).send(JSON.parse(frame))
    end
  rescue Crystalfaux::ConnectionClosed
    # The other side closed; nothing more can be forwarded.
  ensure
    to.close
  end
end
