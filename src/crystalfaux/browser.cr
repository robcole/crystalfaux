module Crystalfaux
  # A running Camoufox browser, driven over the Juggler pipe.
  #
  # ```
  # browser = Crystalfaux::Browser.launch(Crystalfaux::Launcher::Options.new(headless: true))
  # page = browser.new_context.new_page
  # page.goto("data:text/html,<title>crystalfaux</title>")
  # page.title # => "crystalfaux"
  # browser.close
  # ```
  #
  # Ownership:
  #
  # - A launched browser owns its `Launcher::BrowserProcess` and its
  #   `Juggler::Connection`. `#close` sends `Browser.close`, closes the pipe,
  #   then signals the process and removes the temporary profile, through
  #   `Launcher::BrowserProcess#close`.
  # - The browser keeps the registry of contexts and pages. Closing the
  #   browser, or losing the pipe, closes every context and page and fails
  #   every waiting call with `ConnectionClosed`. After the pipe is lost,
  #   call `#close` to stop the process.
  #
  # Fibers: the browser starts none. Its handlers for
  # `Browser.attachedToTarget` and `Browser.detachedFromTarget` run on the
  # connection's reader fiber, and create and close `Page` objects there.
  class Browser
    DEFAULT_TIMEOUT = 30.seconds

    # How long `#close` waits for `Browser.close` to be written when there is
    # no process to stop.
    CLOSE_GRACE = 5.seconds

    # The browser version, for example `"Firefox/152.0.4-beta.31"`.
    getter version : String = ""

    # The browser's default user agent.
    getter user_agent : String = ""

    # The browser process, or `nil` for a browser from `.connect` without
    # one.
    getter process : Launcher::BrowserProcess?

    # :nodoc:
    getter connection : Juggler::Connection

    @lock = Sync::Mutex.new
    @contexts = {} of String => Context
    # Pages by target id.
    @pages = {} of String => Page
    # `#wait_for_page` calls by target id.
    @page_waiters = {} of String => Channel(Page | Exception)
    @closed = false
    @shut_down = false

    # Finds the Camoufox executable, checks that its version speaks the
    # vendored protocol, starts it and connects to it.
    #
    # Raises `LaunchError` when no executable is found or the browser does
    # not start, `UnsupportedBrowserError` when its version is not
    # supported, and what `.connect` raises. On failure, the process is
    # stopped and its temporary profile removed.
    def self.launch(options : Launcher::Options = Launcher::Options.new,
                    timeout : Time::Span = DEFAULT_TIMEOUT) : self
      executable = Launcher::Discovery.executable(options.executable)
      unless executable
        raise LaunchError.new("Camoufox executable not found; set CRYSTALFAUX_CAMOUFOX or install Camoufox")
      end
      Protocol.check_install(Launcher::Discovery.install_dir(executable))
      process = Launcher::BrowserProcess.launch(options.copy_with(executable: executable), timeout)
      connection = Juggler::Connection.new(process.transport)
      begin
        connect(connection, process, timeout)
      rescue ex
        process.close(connection)
        connection.close
        raise ex
      end
    end

    # Drives the browser at the other end of *connection*: subscribes to
    # page targets, then sends `Browser.enable` (without the default
    # context) and `Browser.getInfo`, as Playwright's
    # `server/firefox/ffBrowser.ts` does.
    #
    # The browser owns *connection* and *process* from then on. When the
    # handshake raises, the caller still owns them.
    def self.connect(connection : Juggler::Connection, process : Launcher::BrowserProcess? = nil,
                     timeout : Time::Span = DEFAULT_TIMEOUT) : self
      browser = new(connection, process)
      browser.handshake(timeout)
      browser
    end

    private def initialize(@connection : Juggler::Connection, @process : Launcher::BrowserProcess?)
      @connection.on(Protocol::Browser::AttachedToTarget::METHOD) do |params|
        attached(Protocol.decode(Protocol::Browser::AttachedToTarget, params))
      end
      @connection.on(Protocol::Browser::DetachedFromTarget::METHOD) do |params|
        detached(Protocol.decode(Protocol::Browser::DetachedFromTarget, params))
      end
      @connection.on_close { release_all(ConnectionClosed.new("Juggler connection closed")) }
    end

    # Creates an isolated context. The browser removes it when the pipe
    # closes.
    def new_context(timeout : Time::Span = DEFAULT_TIMEOUT) : Context
      check_open
      request = Protocol::Browser::CreateBrowserContext.new(remove_on_detach: true)
      id = Protocol.call(@connection, request, timeout: timeout).browser_context_id
      context = Context.new(self, id)
      @lock.synchronize do
        raise ConnectionClosed.new("Browser is closed") if @closed
        @contexts[id] = context
      end
      context
    end

    # The open contexts, in the order they were created.
    def contexts : Array(Context)
      @lock.synchronize { @contexts.values }
    end

    # The open pages of every context.
    def pages : Array(Page)
      @lock.synchronize { @pages.values }
    end

    # Closes every context and page, then stops the browser. Safe to call
    # more than once, and after the pipe was lost.
    #
    # With a process, runs `Launcher::BrowserProcess#close`. Without one,
    # sends `Browser.close` and closes the connection.
    def close : Nil
      return if start_shut_down
      release_all(ConnectionClosed.new("Browser is closed"))
      if process = @process
        process.close(@connection)
      else
        request_close
      end
      @connection.close
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    protected def handshake(timeout : Time::Span) : Nil
      enable = Protocol::Browser::Enable.new(attach_to_default_context: false,
        user_prefs: [] of Protocol::Browser::UserPreference)
      Protocol.call(@connection, enable, timeout: timeout)
      info = Protocol.call(@connection, Protocol::Browser::GetInfo.new, timeout: timeout)
      @version = info.version
      @user_agent = info.user_agent
    end

    # Returns the page of *target_id* once `Browser.attachedToTarget` has
    # registered it.
    protected def wait_for_page(target_id : String, deadline : Time::Instant) : Page
      waiter = @lock.synchronize do
        raise ConnectionClosed.new("Browser is closed") if @closed
        page = @pages[target_id]?
        return page if page
        @page_waiters[target_id] = Channel(Page | Exception).new(1)
      end
      select
      when outcome = waiter.receive
        raise outcome if outcome.is_a?(Exception)
        outcome
      when timeout({deadline - Time.instant, Time::Span.zero}.max)
        @lock.synchronize { @page_waiters.delete(target_id) }
        raise TimeoutError.new("Page #{target_id} was not attached in time")
      end
    end

    # Forgets *page* and closes it with *reason*.
    protected def remove_page(page : Page, reason : Exception) : Nil
      @lock.synchronize { @pages.delete(page.target_id) }
      page.dispose(reason)
    end

    # Forgets *context* and closes its pages.
    protected def remove_context(context : Context) : Nil
      pages = @lock.synchronize do
        @contexts.delete(context.id)
        @pages.values.select(&.context.same?(context)).tap(&.each { |page| @pages.delete(page.target_id) })
      end
      reason = PageClosed.new("Context #{context.id} is closed")
      pages.each(&.dispose(reason))
    end

    private def check_open : Nil
      raise ConnectionClosed.new("Browser is closed") if closed?
    end

    private def start_shut_down : Bool
      @lock.synchronize do
        was_shut_down = @shut_down
        @shut_down = true
        was_shut_down
      end
    end

    private def request_close : Nil
      @connection.notify(Protocol::Browser::Close::METHOD, Protocol::Browser::Close.new, timeout: CLOSE_GRACE)
    rescue ConnectionClosed | TimeoutError
      # The pipe is already closed or stuck; closing the connection follows.
    end

    # Marks the browser closed, then closes every context and page and fails
    # every `#wait_for_page` call with *reason*. Only the first call does
    # anything.
    private def release_all(reason : Exception) : Nil
      contexts, pages, waiters = @lock.synchronize do
        return if @closed
        @closed = true
        taken = {@contexts.values, @pages.values, @page_waiters.values}
        @contexts.clear
        @pages.clear
        @page_waiters.clear
        taken
      end
      contexts.each(&.mark_closed)
      pages.each(&.dispose(reason))
      waiters.each(&.send(reason))
    end

    # Runs on the reader fiber. Creating the page here subscribes it to its
    # session before the session's first event is read.
    private def attached(event : Protocol::Browser::AttachedToTarget) : Nil
      context_id = event.target_info.browser_context_id
      context = context_id.try { |id| @lock.synchronize { @contexts[id]? } }
      # A target of a context this browser did not create.
      return unless context
      page = Page.new(@connection, event.session_id, event.target_info.target_id, context)
      registered, waiter = @lock.synchronize do
        next {false, nil} if @closed
        @pages[page.target_id] = page
        {true, @page_waiters.delete(page.target_id)}
      end
      return page.dispose(ConnectionClosed.new("Browser is closed")) unless registered
      waiter.try &.send(page)
    end

    private def detached(event : Protocol::Browser::DetachedFromTarget) : Nil
      page = @lock.synchronize { @pages.delete(event.target_id) }
      page.try &.dispose(PageClosed.new("Page #{event.target_id} was closed"))
    end
  end
end
