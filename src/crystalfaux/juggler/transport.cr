# The Juggler wire layer: framing (`Transport`), requests, replies and
# events (`Connection`). `Browser` builds on it; most programs do not use
# it directly.
module Crystalfaux::Juggler
  # Frames Juggler messages over a duplex `IO`.
  #
  # Each frame is one JSON message followed by a NUL byte, in both directions
  # (Camoufox `additions/juggler/pipe/nsRemoteDebuggingPipe.cpp`, Playwright
  # `server/pipeTransport.ts`). For a browser process, wrap its pipes in an
  # `IO::Stapled` with `sync_close: true`:
  #
  # ```
  # io = IO::Stapled.new(process.output, process.input, sync_close: true)
  # transport = Crystalfaux::Juggler::Transport.new(io)
  # transport.send(%({"id":1,"method":"Browser.getInfo","params":{}}))
  # transport.receive # => %({"id":1,"result":{...}})
  # ```
  #
  # The transport owns the `IO`: `#close` closes it. Closing the write end is
  # what makes Camoufox exit, because `Browser.close` alone does not.
  #
  # `#send` is safe to call from several fibers at once. `#receive` is meant
  # for one reader fiber.
  class Transport
    FRAME_END = '\0'

    @write_lock = Sync::Mutex.new
    @closed = Atomic(Bool).new(false)

    def initialize(@io : IO)
    end

    # Writes *frame* followed by a NUL byte and flushes.
    #
    # Raises `ConnectionClosed` when the transport is closed or the other end
    # has gone away.
    def send(frame : String) : Nil
      @write_lock.synchronize do
        raise ConnectionClosed.new("Juggler transport is closed") if closed?
        @io << frame << FRAME_END
        @io.flush
      end
    rescue ex : IO::Error
      raise ConnectionClosed.new("Juggler pipe write failed: #{ex.message}", cause: ex)
    end

    # Blocks until a complete frame arrives and returns it without the NUL.
    #
    # Returns `nil` at end of stream, after `#close`, or when the stream ends
    # in the middle of a frame (the partial frame is dropped).
    def receive : String?
      return if closed?
      frame = @io.gets(FRAME_END, chomp: false)
      return unless frame && frame.ends_with?(FRAME_END)
      frame.rchop
    rescue IO::Error
      # Raised when another fiber closes the IO during a blocked read.
      nil
    end

    # Closes the underlying `IO`. Safe to call more than once.
    def close : Nil
      return if @closed.swap(true)
      @io.close
    rescue IO::Error
      # The other end already closed the pipe; nothing is left to release.
    end

    # Whether `#close` ran.
    def closed? : Bool
      @closed.get
    end
  end
end
