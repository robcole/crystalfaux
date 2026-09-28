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
    # Raises `TimeoutError` when that takes longer than *timeout*,
    # `PageClosed` when the context closes first or the page closes before
    # it is ready, and `ConnectionClosed` when the browser closes.
    #
    # On failure after the target exists, the page is forgotten and its
    # target closed (bounded by `Browser::CLEANUP_TIMEOUT`), and the
    # original error is raised. A target that attaches after the call gave
    # up is closed too. The target is unknown only when the call failed
    # before it got the `Browser.newPage` reply: the reply never arrived, or
    # arrived after *timeout* and was dropped. A page that then attaches
    # stays in the context until `#close`.
    def new_page(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Page
      deadline = Time.instant + timeout
      # Registered before the request, so a page that attaches, or even
      # detaches, before the reply is kept for this call.
      creation = @browser.begin_creation(self)
      page : Page? = nil
      begin
        request = Protocol::Browser::NewPage.new(@id)
        target_id = Protocol.call(@browser.connection, request, timeout: timeout,
          cancellation: creation.cancellation).target_id
        page = @browser.claim_page(creation, target_id, deadline)
        page.wait_until_ready(deadline)
      rescue ex
        @browser.finish_creation(creation, page, succeeded: false)
        raise ex
      end
      @browser.finish_creation(creation, page, succeeded: true)
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
