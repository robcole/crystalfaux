module Crystalfaux::Juggler
  # Stops `Connection#call`s that wait for a reply, before their timeout.
  #
  # The owner of the calls, such as a page, passes the same cancellation to
  # each call and cancels it once, with the exception the calls must raise:
  #
  # ```
  # cancellation = Crystalfaux::Juggler::Cancellation.new
  # spawn { connection.call("Runtime.evaluate", params, session_id, cancellation: cancellation) }
  # cancellation.cancel(Crystalfaux::PageCrashed.new("Page crashed"))
  # # the call raises that PageCrashed
  # ```
  #
  # A cancelled call releases its pending entry; its reply is dropped when
  # it arrives. The connection stays open for other calls. A call made after
  # the cancellation raises at once.
  class Cancellation
    # Closed by `#cancel`, which wakes every call that selects on it.
    getter signal = Channel(Nil).new
    @reason : Exception?
    @lock = Sync::Mutex.new

    # Cancels with *reason*. Only the first call counts.
    def cancel(reason : Exception) : Nil
      first = @lock.synchronize do
        next false if @reason
        @reason = reason
        true
      end
      @signal.close if first
    end

    # The exception given to `#cancel`, or `nil` before it.
    def reason : Exception?
      @lock.synchronize { @reason }
    end
  end
end
