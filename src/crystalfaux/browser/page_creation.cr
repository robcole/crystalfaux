module Crystalfaux
  class Browser
    # :nodoc:
    #
    # One `Context#new_page` call in progress. `Browser` registers it before
    # `Browser.newPage` is sent, so every page that attaches in its context
    # meanwhile is kept for it (see `Browser#claim_page`).
    #
    # The browser fills in `#target_id` from the reply and hands over the
    # attached page with `#deliver`, on the reader fiber, without blocking.
    # Closing the context or the browser cancels `#cancellation`, which ends
    # both the `Browser.newPage` request and `#wait`.
    class PageCreation
      getter context : Context
      getter cancellation = Juggler::Cancellation.new

      # The target id from the `Browser.newPage` reply; `nil` before it.
      # Read and written under the browser's lock.
      property target_id : String?

      # Capacity 1: the reader delivers at most one page and never waits.
      @attached = Channel(Page).new(1)

      def initialize(@context : Context)
      end

      def deliver(page : Page) : Nil
        @attached.send(page)
      end

      # Returns the delivered page. Raises the cancellation reason, or
      # `TimeoutError` at *deadline*.
      def wait(deadline : Time::Instant) : Page
        select
        when page = @attached.receive
          page
        when @cancellation.signal.receive?
          raise(@cancellation.reason || PageClosed.new("Page creation was cancelled"))
        when timeout({deadline - Time.instant, Time::Span.zero}.max)
          raise TimeoutError.new("Page #{@target_id} was not attached in time")
        end
      end
    end
  end
end
