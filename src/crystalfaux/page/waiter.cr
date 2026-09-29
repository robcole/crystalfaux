module Crystalfaux
  class Page
    # :nodoc:
    #
    # Queues a page's lifecycle events, and the responses of navigation
    # requests, for one waiting call, such as `Page#goto`.
    #
    # The page registers the waiter before the call sends its request, so
    # events that arrive before the reply are kept. The page's event
    # handlers call `#push` on the reader fiber and never block; the waiting
    # fiber takes the events in order in `#wait`. `#fail` ends the wait with
    # an exception, for example when the page crashes or the connection
    # closes. The page removes the waiter when the call returns.
    class Waiter
      alias Event = Protocol::Page::NavigationCommitted | Protocol::Page::NavigationAborted |
                    Protocol::Page::EventFired | Protocol::Page::Ready | Response

      @events = Deque(Event).new
      @failure : Exception?
      @lock = Sync::Mutex.new
      # Capacity 1: one pending wake-up covers any number of pushes.
      @wake = Channel(Nil).new(1)

      def push(event : Event) : Nil
        @lock.synchronize { @events << event }
        wake
      end

      def fail(exception : Exception) : Nil
        @lock.synchronize { @failure ||= exception }
        wake
      end

      # Yields each event in order until the block returns `true`. Raises
      # the exception given to `#fail` once the queued events are used up,
      # and `TimeoutError` with *description* at *deadline*.
      def wait(deadline : Time::Instant, description : String, & : Event -> Bool) : Nil
        loop do
          event, failure = @lock.synchronize { {@events.shift?, @failure} }
          if event
            return if yield event
            next
          end
          raise failure if failure
          select
          when @wake.receive
          when timeout({deadline - Time.instant, Time::Span.zero}.max)
            raise TimeoutError.new("#{description} timed out")
          end
        end
      end

      private def wake : Nil
        select
        when @wake.send(nil)
        else
          # A wake-up is already pending.
        end
      end
    end
  end
end
