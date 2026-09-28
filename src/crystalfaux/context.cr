module Crystalfaux
  # An isolated browser context: its own cookies, storage and cache, like a
  # private window.
  #
  # ```
  # context = browser.new_context
  # page = context.new_page
  # context.close # closes the page too
  # ```
  #
  # The browser removes the context when the Juggler pipe closes, because
  # `Browser#new_context` creates it with `removeOnDetach`. `Browser` keeps
  # the registry of pages; `#pages` reads it.
  class Context
    # The Juggler browser context id.
    getter id : String

    # The browser that owns the context.
    getter browser : Browser

    @closed = false
    @lock = Sync::Mutex.new

    # :nodoc:
    def initialize(@browser : Browser, @id : String)
    end

    # Opens a page in this context and returns it once the browser reports
    # it ready (`Page.ready`): its main frame and first document exist.
    #
    # Raises `TimeoutError` when that takes longer than *timeout*, `Error`
    # when the context is closed, and `ConnectionClosed` when the browser is.
    def new_page(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Page
      deadline = Time.instant + timeout
      raise Error.new("Context #{@id} is closed") if closed?
      # The browser registers the page when `Browser.attachedToTarget`
      # arrives, which Juggler sends before this reply.
      target_id = Protocol.call(@browser.connection, Protocol::Browser::NewPage.new(@id), timeout: timeout).target_id
      page = @browser.wait_for_page(target_id, deadline)
      page.wait_until_ready(deadline)
      page
    end

    # The open pages of this context.
    def pages : Array(Page)
      @browser.pages.select(&.context.same?(self))
    end

    # Removes the browser context, which closes its pages. Safe to call more
    # than once.
    #
    # Sends `Browser.removeBrowserContext`, then forgets the context and its
    # pages even when that request fails. Raises what the request raises,
    # except `ConnectionClosed`.
    def close(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      return if mark_closed
      begin
        Protocol.call(@browser.connection, Protocol::Browser::RemoveBrowserContext.new(@id), timeout: timeout)
      rescue ConnectionClosed
        # The browser is gone, and the context with it.
      ensure
        @browser.remove_context(self)
      end
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    # Marks the context closed and returns whether it already was.
    protected def mark_closed : Bool
      @lock.synchronize do
        was_closed = @closed
        @closed = true
        was_closed
      end
    end
  end
end
