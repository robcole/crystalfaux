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

    # Never closed: the cancellation signal of a call without one.
    NO_CANCELLATION = Channel(Nil).new

    @lock = Sync::Mutex.new
    @next_id = 0_i64
    @pending = {} of Int64 => Channel(JSON::Any)
    @subscriptions = {} of {String?, String} => Array(Subscription)
    @closed = false
    @close_handlers = [] of ->
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
    # When *cancellation* is cancelled before the reply arrives, raises its
    # reason and drops the reply; the connection stays open.
    #
    # The timeout also covers waiting for the writer and the write itself.
    # When it expires before the request frame is fully written, the
    # connection closes, because a partial frame corrupts the framing of
    # every later message.
    def call(method : String, params : (JSON::Serializable | Hash | NamedTuple | JSON::Any)? = nil,
             session_id : String? = nil, timeout : Time::Span = DEFAULT_TIMEOUT,
             cancellation : Cancellation? = nil) : JSON::Any
      deadline = Time.instant + timeout
      cancellation.try &.reason.try { |reason| raise reason }
      id, reply = register_request
      begin
        # Encoding can raise (for example on NaN), so it runs inside the
        # block that releases the pending entry.
        request = Outgoing.new(encode(id, method, params, session_id))
        hand_off(request, method, timeout, deadline, cancellation)
        message = await(reply, request, method, timeout, deadline, cancellation)
      ensure
        @lock.synchronize { @pending.delete(id) }
      end
      result_of(method, message)
    end

    # Writes *method* with *params* to *session_id* and returns once the
    # request frame is written, without waiting for a reply. A reply that
    # arrives later is dropped.
    #
    # Use it for requests whose reply may never come, such as `Browser.close`
    # (Playwright `server/firefox/firefox.ts` ignores that reply too).
    # Raises `TimeoutError` when the frame is not fully written within
    # *timeout*, and `ConnectionClosed` when the connection is or becomes
    # closed first. As with `#call`, a timeout during the write closes the
    # connection.
    def notify(method : String, params : (JSON::Serializable | Hash | NamedTuple | JSON::Any)? = nil,
               session_id : String? = nil, timeout : Time::Span = DEFAULT_TIMEOUT) : Nil
      deadline = Time.instant + timeout
      request = Outgoing.new(encode(next_request_id, method, params, session_id))
      hand_off(request, method, timeout, deadline, nil)
      select
      when request.finished.receive?
        return if request.written?
        raise ConnectionClosed.new("Juggler connection closed while writing #{method}")
      when timeout(remaining(deadline))
        close unless request.written?
        raise timed_out(method, timeout)
      end
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

    # Calls the block once when the connection closes, whether `#close` was
    # called or the pipe broke or reached end of stream. Calls it at once when
    # the connection is already closed.
    #
    # The block runs on the fiber that closes the connection, after pending
    # calls have failed. It must not wait on `#call`. An exception from the
    # block is logged.
    #
    # Returns the handler; pass it to `#off_close` to remove it.
    def on_close(&handler : ->) : ->
      already_closed = @lock.synchronize do
        @close_handlers << handler unless @closed
        @closed
      end
      run_close_handler(handler) if already_closed
      handler
    end

    # Removes a handler that `#on_close` returned.
    def off_close(handler : ->) : Nil
      @lock.synchronize { @close_handlers.delete(handler) }
    end

    # Fails every pending call with `ConnectionClosed`, closes the transport
    # and runs the `#on_close` handlers. Safe to call more than once; the
    # handlers run only the first time.
    def close : Nil
      pending, handlers = @lock.synchronize do
        @closed = true
        {@pending.values.tap { @pending.clear }, @close_handlers.dup.tap { @close_handlers.clear }}
      end
      pending.each(&.close)
      @outbox.close
      @transport.close
      handlers.each { |handler| run_close_handler(handler) }
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    private def run_close_handler(handler : ->) : Nil
      handler.call
    rescue ex
      Log.error(exception: ex) { "Juggler close handler raised" }
    end

    private def register_request : {Int64, Channel(JSON::Any)}
      @lock.synchronize do
        id = allocate_id
        # Capacity 1 lets the reader deliver without waiting for the caller.
        reply = Channel(JSON::Any).new(1)
        @pending[id] = reply
        {id, reply}
      end
    end

    private def next_request_id : Int64
      @lock.synchronize { allocate_id }
    end

    # Call with `@lock` held.
    private def allocate_id : Int64
      raise ConnectionClosed.new("Juggler connection is closed") if @closed
      @next_id += 1
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

    private def hand_off(request : Outgoing, method : String, timeout : Time::Span, deadline : Time::Instant,
                         cancellation : Cancellation?) : Nil
      select
      when @outbox.send(request)
      when signal_of(cancellation).receive?
        # The writer never took the request, so no bytes of it were written.
        raise cancelled(cancellation)
      when timeout(remaining(deadline))
        # The writer never took the request, so no bytes of it were written.
        raise timed_out(method, timeout)
      end
    rescue Channel::ClosedError
      raise ConnectionClosed.new("Juggler connection closed before #{method} was sent")
    end

    private def await(reply : Channel(JSON::Any), request : Outgoing, method : String,
                      timeout : Time::Span, deadline : Time::Instant, cancellation : Cancellation?) : JSON::Any
      select
      when message = reply.receive?
        message || raise ConnectionClosed.new("Juggler connection closed while waiting for #{method}")
      when signal_of(cancellation).receive?
        # The writer finishes the frame if it has not yet; the reply is dropped.
        raise cancelled(cancellation)
      when timeout(remaining(deadline))
        close unless request.written?
        raise timed_out(method, timeout)
      end
    end

    private def signal_of(cancellation : Cancellation?) : Channel(Nil)
      cancellation.try(&.signal) || NO_CANCELLATION
    end

    private def cancelled(cancellation : Cancellation?) : Exception
      cancellation.try(&.reason) || raise "BUG: cancellation signalled without a reason"
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
        begin
          @transport.send(request.frame)
          request.written = true
        ensure
          request.finish
        end
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
    # `#finished` closes when the writer is done with the frame, whether the
    # write succeeded or failed.
    private class Outgoing
      getter frame : String
      getter finished = Channel(Nil).new
      @written = Atomic(Bool).new(false)

      def initialize(@frame : String)
      end

      def written? : Bool
        @written.get
      end

      def written=(value : Bool) : Bool
        @written.set(value)
      end

      def finish : Nil
        @finished.close
      end
    end
  end
end
