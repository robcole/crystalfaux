require "json"
require "log"

module Crystalfaux::Juggler
  # Sends Juggler requests and routes replies and events over a `Transport`.
  #
  # Every request has an `id`, a `method`, `params` and an optional
  # `sessionId`. `Browser.*` methods use the root session (no `sessionId`);
  # each page target has its own session, announced by the
  # `Browser.attachedToTarget` event (Camoufox
  # `additions/juggler/protocol/Dispatcher.js`).
  #
  # ```
  # connection = Crystalfaux::Juggler::Connection.new(transport)
  # connection.on("Browser.attachedToTarget") do |params|
  #   puts params["sessionId"]
  # end
  # connection.call("Browser.getInfo")["version"] # => "Firefox/152.0.4-beta.31"
  # connection.call("Page.navigate", {frameId: frame_id, url: url}, session_id)
  # connection.close
  # ```
  #
  # Fiber lifecycle: `.new` starts a reader fiber and a writer fiber. The
  # reader reads frames until the transport reaches end of stream or is
  # closed. The writer writes one request frame at a time until the
  # connection closes or a write fails. When either fiber stops, the
  # connection disconnects: pending calls raise `ConnectionClosed` and the
  # transport is closed. Frames that arrive after that are not read.
  #
  # The connection owns the transport: `#close` closes it.
  class Connection
    DEFAULT_TIMEOUT = 30.seconds

    Log = ::Log.for("crystalfaux.juggler")

    @lock = Sync::Mutex.new
    @next_id = 0_i64
    @pending = {} of Int64 => Channel(JSON::Any)
    @subscriptions = {} of {String?, String} => Array(Subscription)
    @closed = false
    # Unbuffered, so a completed send means the writer has started the frame.
    @outbox = Channel(Outgoing).new

    def initialize(@transport : Transport)
      spawn(name: "juggler-reader") { read_frames }
      spawn(name: "juggler-writer") { write_frames }
    end

    # Sends *method* with *params* to *session_id* (the root session when
    # `nil`) and returns the `result` of the reply.
    #
    # *params* is any value that serializes to a JSON object; `nil` sends `{}`.
    # Raises `ProtocolError` when the reply carries an error, `TimeoutError`
    # when the request is not written and answered within *timeout*, and
    # `ConnectionClosed` when the connection is or becomes closed. A reply
    # that arrives after the timeout is dropped.
    #
    # The timeout also covers waiting for the writer and the write itself.
    # When it expires before the request frame is fully written, the
    # connection closes, because a partial frame corrupts the framing of
    # every later message.
    def call(method : String, params : (JSON::Serializable | Hash | NamedTuple | JSON::Any)? = nil,
             session_id : String? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : JSON::Any
      deadline = Time.instant + timeout
      id, reply = register_request
      request = Outgoing.new(encode(id, method, params, session_id))
      begin
        hand_off(request, method, timeout, deadline)
        message = await(reply, request, method, timeout, deadline)
      ensure
        @lock.synchronize { @pending.delete(id) }
      end
      result_of(method, message)
    end

    # Calls the block with the `params` of every *method* event from
    # *session_id* (the root session when `nil`).
    #
    # The block runs on the reader fiber, in frame order, before later
    # replies are delivered. It must not wait on `#call`, because that reply
    # can only arrive after the block returns; `spawn` for such work. An
    # exception from the block is logged and does not stop the reader.
    def on(method : String, session_id : String? = nil, &handler : JSON::Any ->) : Subscription
      subscription = Subscription.new(method, session_id, handler)
      @lock.synchronize do
        (@subscriptions[{session_id, method}] ||= [] of Subscription) << subscription
      end
      subscription
    end

    # Stops calling the handler of *subscription*.
    def off(subscription : Subscription) : Nil
      key = {subscription.session_id, subscription.method}
      @lock.synchronize do
        subscriptions = @subscriptions[key]?
        return unless subscriptions
        subscriptions.delete(subscription)
        @subscriptions.delete(key) if subscriptions.empty?
      end
    end

    # Fails every pending call with `ConnectionClosed` and closes the
    # transport. Safe to call more than once.
    def close : Nil
      pending = @lock.synchronize do
        @closed = true
        @pending.values.tap { @pending.clear }
      end
      pending.each(&.close)
      @outbox.close
      @transport.close
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    private def register_request : {Int64, Channel(JSON::Any)}
      @lock.synchronize do
        raise ConnectionClosed.new("Juggler connection is closed") if @closed
        id = @next_id += 1
        # Capacity 1 lets the reader deliver without waiting for the caller.
        reply = Channel(JSON::Any).new(1)
        @pending[id] = reply
        {id, reply}
      end
    end

    private def encode(id : Int64, method : String, params, session_id : String?) : String
      JSON.build do |json|
        json.object do
          json.field "id", id
          json.field "method", method
          json.field "params" do
            params ? params.to_json(json) : json.object { }
          end
          json.field "sessionId", session_id if session_id
        end
      end
    end

    private def hand_off(request : Outgoing, method : String, timeout : Time::Span, deadline : Time::Instant) : Nil
      select
      when @outbox.send(request)
      when timeout(remaining(deadline))
        # The writer never took the request, so no bytes of it were written.
        raise timed_out(method, timeout)
      end
    rescue Channel::ClosedError
      raise ConnectionClosed.new("Juggler connection closed before #{method} was sent")
    end

    private def await(reply : Channel(JSON::Any), request : Outgoing, method : String,
                      timeout : Time::Span, deadline : Time::Instant) : JSON::Any
      select
      when message = reply.receive?
        message || raise ConnectionClosed.new("Juggler connection closed while waiting for #{method}")
      when timeout(remaining(deadline))
        close unless request.written?
        raise timed_out(method, timeout)
      end
    end

    private def remaining(deadline : Time::Instant) : Time::Span
      {deadline - Time.instant, Time::Span.zero}.max
    end

    private def timed_out(method : String, timeout : Time::Span) : TimeoutError
      TimeoutError.new("#{method} timed out after #{timeout}")
    end

    private def result_of(method : String, message : JSON::Any) : JSON::Any
      if error = message["error"]?
        reason = error["message"]?.try(&.as_s?) || error.to_json
        raise ProtocolError.new(method, reason)
      end
      message["result"]? || JSON::Any.new(nil)
    end

    private def write_frames : Nil
      while request = @outbox.receive?
        @transport.send(request.frame)
        request.written = true
      end
    rescue ConnectionClosed
      # The pipe is broken; no later request can be written either.
    ensure
      close
    end

    private def read_frames : Nil
      while frame = @transport.receive
        dispatch(frame)
      end
    ensure
      close
    end

    private def dispatch(frame : String) : Nil
      message = JSON.parse(frame)
      if id = message["id"]?.try(&.as_i64?)
        resolve(id, message)
      elsif method = message["method"]?.try(&.as_s?)
        emit(method, message["sessionId"]?.try(&.as_s?), message["params"]? || JSON::Any.new({} of String => JSON::Any))
      end
    rescue ex : JSON::ParseException
      Log.warn(exception: ex) { "Skipped a Juggler frame that is not valid JSON" }
    end

    private def resolve(id : Int64, message : JSON::Any) : Nil
      reply = @lock.synchronize { @pending.delete(id) }
      # No pending entry means the call timed out; drop the late reply.
      reply.try &.send(message)
    end

    private def emit(method : String, session_id : String?, params : JSON::Any) : Nil
      subscriptions = @lock.synchronize { @subscriptions[{session_id, method}]?.try(&.dup) }
      subscriptions.try &.each do |subscription|
        subscription.handler.call(params)
      rescue ex
        Log.error(exception: ex) { "Juggler event handler for #{method} raised" }
      end
    end

    # A request frame and whether the writer has finished writing it.
    private class Outgoing
      getter frame : String
      @written = Atomic(Bool).new(false)

      def initialize(@frame : String)
      end

      def written? : Bool
        @written.get
      end

      def written=(value : Bool) : Bool
        @written.set(value)
      end
    end
  end
end
