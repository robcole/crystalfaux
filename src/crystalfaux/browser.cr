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
  # - The browser keeps the registry of contexts, pages, and page creations
  #   in progress (`PageCreation`). Closing the browser, or losing the pipe,
  #   closes every context and page, fails every waiting call with
  #   `ConnectionClosed`, and removes the browser's own event subscriptions.
  #   After the pipe is lost, call `#close` to stop the process.
  #
  # Fibers: the browser keeps none running. Its handlers for
  # `Browser.attachedToTarget` and `Browser.detachedFromTarget` run on the
  # connection's reader fiber, and create and close `Page` objects there.
  # When a page attaches for a `Context#new_page` call that already gave up,
  # the handler spawns one fiber that closes the target, bounded by
  # `CLEANUP_TIMEOUT`. The fiber sends through the browser-owned connection
  # and also stops when that connection closes; `#close` does not wait for
  # it.
  class Browser
    # How long a browser, context or page call waits by default.
    DEFAULT_TIMEOUT = 30.seconds

    # What `#register` returns for a page whose creation gave up.
    private record Abandoned

    # How long `#close` waits for `Browser.close` to be written when there is
    # no process to stop.
    CLOSE_GRACE = 5.seconds

    # How long closing an unwanted page target may take, after
    # `Context#new_page` failed.
    CLEANUP_TIMEOUT = 5.seconds

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
    # Open pages by target id.
    @pages = {} of String => Page
    # `Context#new_page` calls in progress.
    @creations = [] of PageCreation
    # Pages that attached while a creation in their context had no target id
    # yet, by target id. A creation claims its page here; a page stays here
    # after it detaches, so the creation learns that it closed.
    @unclaimed = {} of String => Page
    # Target ids whose creation gave up before they attached.
    @abandoned = Set(String).new
    @subscriptions = [] of Juggler::Subscription
    @close_handler : (->)?
    @closed = false
    @shut_down = false

    # Finds the Camoufox executable, checks that its version speaks the
    # vendored protocol, starts it and connects to it. With a *proxy*, every
    # request of the browser goes through it, unless a context has its own
    # (`#new_context`).
    #
    # Raises `LaunchError` when no executable is found or the browser does
    # not start, `UnsupportedBrowserError` when its version is not
    # supported, and what the handshake raises. On failure, the process is
    # stopped and its temporary profile removed.
    def self.launch(options : Launcher::Options = Launcher::Options.new,
                    timeout : Time::Span = DEFAULT_TIMEOUT, *, proxy : Proxy? = nil) : self
      executable = Launcher::Discovery.executable(options.executable)
      unless executable
        raise LaunchError.new("Camoufox executable not found; set CRYSTALFAUX_CAMOUFOX or install Camoufox")
      end
      Protocol.check_install(Launcher::Discovery.install_dir(executable))
      process = Launcher::BrowserProcess.launch(options.copy_with(executable: executable), timeout)
      connection = Juggler::Connection.new(process.transport)
      begin
        connect(connection, process, timeout, proxy: proxy)
      rescue ex
        process.close(connection)
        connection.close
        raise ex
      end
    end

    # Launches the browser with a fingerprint *config* and Firefox *prefs*,
    # which replace those of *options*. Both reach the browser in its
    # environment (`Launcher.environment`), so they apply from startup.
    #
    # ```
    # config = Crystalfaux::Fingerprint::Config.for(os: :mac, screen: Crystalfaux::Fingerprint::Screen.new(1512, 982),
    #   user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:152.0) Gecko/20100101 Firefox/152.0")
    # browser = Crystalfaux::Browser.launch(config: config)
    # ```
    #
    # NOTE: *prefs* have no effect on the supported builds
    # (`152.0.4-beta.30` and `beta.31`). Their `camoufox.cfg` does not read
    # `CAMOU_PREFS_n`; only newer Camoufox builds do. A fix that sends prefs
    # through `Browser.enable` `userPrefs` is scheduled.
    def self.launch(*, config : Fingerprint::Config, prefs : Hash(String, JSON::Any) = {} of String => JSON::Any,
                    proxy : Proxy? = nil, options : Launcher::Options = Launcher::Options.new,
                    timeout : Time::Span = DEFAULT_TIMEOUT) : self
      launch(options.copy_with(config: config.to_h, prefs: prefs), timeout, proxy: proxy)
    end

    # :nodoc:
    #
    # Drives the browser at the other end of *connection*: subscribes to
    # page targets, then sends `Browser.enable` (without the default
    # context), `Browser.setBrowserProxy` when there is a *proxy*, and
    # `Browser.getInfo`, as Playwright's `server/firefox/ffBrowser.ts` does.
    # `.launch` and the specs use it.
    #
    # The browser owns *connection* and *process* from then on. When the
    # handshake raises, it removes its handlers from *connection*, and the
    # caller still owns both.
    def self.connect(connection : Juggler::Connection, process : Launcher::BrowserProcess? = nil,
                     timeout : Time::Span = DEFAULT_TIMEOUT, *, proxy : Proxy? = nil) : self
      browser = new(connection, process)
      begin
        browser.handshake(timeout, proxy)
      rescue ex
        browser.unsubscribe
        raise ex
      end
      browser
    end

    private def initialize(@connection : Juggler::Connection, @process : Launcher::BrowserProcess?)
      @subscriptions << @connection.on(Protocol::Browser::AttachedToTarget::METHOD) do |params|
        attached(Protocol.decode(Protocol::Browser::AttachedToTarget, params))
      end
      @subscriptions << @connection.on(Protocol::Browser::DetachedFromTarget::METHOD) do |params|
        detached(Protocol.decode(Protocol::Browser::DetachedFromTarget, params))
      end
      @close_handler = @connection.on_close { release_all(ConnectionClosed.new("Juggler connection closed")) }
    end

    # Creates an isolated context. The browser removes it when the pipe
    # closes. With a *proxy*, the context's requests go through it instead
    # of the browser's proxy; when the browser rejects the proxy, the
    # context is closed and the error raised.
    def new_context(timeout : Time::Span = DEFAULT_TIMEOUT, *, proxy : Proxy? = nil) : Context
      check_open
      request = Protocol::Browser::CreateBrowserContext.new(remove_on_detach: true)
      id = Protocol.call(@connection, request, timeout: timeout).browser_context_id
      context = Context.new(self, id)
      @lock.synchronize do
        raise ConnectionClosed.new("Browser is closed") if @closed
        @contexts[id] = context
      end
      context.use_proxy(proxy, timeout) if proxy
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

    # Whether `#close` ran or the pipe to the browser closed.
    def closed? : Bool
      @lock.synchronize { @closed }
    end

    protected def handshake(timeout : Time::Span, proxy : Proxy?) : Nil
      enable = Protocol::Browser::Enable.new(attach_to_default_context: false,
        user_prefs: [] of Protocol::Browser::UserPreference)
      Protocol.call(@connection, enable, timeout: timeout)
      if proxy
        request = Protocol::Browser::SetBrowserProxy.new(proxy.type, proxy.host, proxy.port, proxy.bypass,
          proxy.username, proxy.password)
        Protocol.call(@connection, request, timeout: timeout)
      end
      info = Protocol.call(@connection, Protocol::Browser::GetInfo.new, timeout: timeout)
      @version = info.version
      @user_agent = info.user_agent
    end

    # Removes the browser's event and close handlers from the connection.
    protected def unsubscribe : Nil
      subscriptions = @lock.synchronize { @subscriptions.dup.tap { @subscriptions.clear } }
      subscriptions.each { |subscription| @connection.off(subscription) }
      @close_handler.try { |handler| @connection.off_close(handler) }
    end

    # Registers a page creation in *context*. Call it before sending
    # `Browser.newPage`, and `#finish_creation` when done.
    protected def begin_creation(context : Context) : PageCreation
      creation = PageCreation.new(context)
      @lock.synchronize do
        raise ConnectionClosed.new("Browser is closed") if @closed
        raise PageClosed.new("Context #{context.id} is closed") if context.closed?
        @creations << creation
      end
      creation
    end

    # Returns the page of *target_id*, the target that `Browser.newPage`
    # created for *creation*, once it has attached. The page may already be
    # closed when it detached before this call.
    protected def claim_page(creation : PageCreation, target_id : String, deadline : Time::Instant) : Page
      page = @lock.synchronize do
        creation.target_id = target_id
        @unclaimed.delete(target_id)
      end
      page || creation.wait(deadline)
    end

    # Ends *creation*. On failure, closes the page it got, if any, or
    # remembers its target so a late attach is closed. When no other
    # creation is pending in the context, closes the pages that attached
    # for creations that never learned their target id.
    protected def finish_creation(creation : PageCreation, page : Page?, succeeded : Bool) : Nil
      unwanted = @lock.synchronize do
        @creations.delete(creation)
        failed = [] of Page
        unless succeeded
          target_id = creation.target_id
          # The page may have attached after the wait for it timed out.
          page ||= target_id.try { |id| @pages[id]? }
          if page
            failed << page
          elsif target_id
            @abandoned << target_id
          end
        end
        discarded = (failed + orphans_of(creation.context)).uniq
        discarded.each do |orphan|
          @pages.delete(orphan.target_id)
          @unclaimed.delete(orphan.target_id)
        end
        discarded
      end
      unwanted.each { |orphan| discard(orphan) }
    end

    # Forgets *page* and closes it with *reason*.
    protected def remove_page(page : Page, reason : Exception) : Nil
      @lock.synchronize { @pages.delete(page.target_id) }
      page.dispose(reason)
    end

    # Forgets *context*, closes its pages, and cancels its page creations.
    protected def remove_context(context : Context) : Nil
      pages, creations = @lock.synchronize do
        @contexts.delete(context.id)
        pages = (@pages.values + @unclaimed.values).select(&.context.same?(context)).uniq!
        pages.each do |page|
          @pages.delete(page.target_id)
          @unclaimed.delete(page.target_id)
        end
        {pages, @creations.select(&.context.same?(context))}
      end
      reason = PageClosed.new("Context #{context.id} is closed")
      pages.each(&.dispose(reason))
      creations.each(&.cancellation.cancel(reason))
    end

    # Call with `@lock` held. The pages that attached in *context* for a
    # creation that is no longer pending.
    private def orphans_of(context : Context) : Array(Page)
      return [] of Page if @creations.any?(&.context.same?(context))
      @unclaimed.values.select(&.context.same?(context))
    end

    # Closes a page that no caller will get, and its target when it is
    # still open. Blocks for at most `CLEANUP_TIMEOUT`.
    private def discard(page : Page) : Nil
      open = !page.closed?
      page.dispose(PageClosed.new("Page #{page.target_id} was discarded"))
      page.close_target(CLEANUP_TIMEOUT) if open
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

    # Marks the browser closed, then closes every context and page, cancels
    # every page creation with *reason*, and removes the browser's handlers
    # from the connection. Only the first call does anything.
    private def release_all(reason : Exception) : Nil
      contexts, pages, creations = @lock.synchronize do
        return if @closed
        @closed = true
        taken = {@contexts.values, (@pages.values + @unclaimed.values).uniq, @creations.dup}
        @contexts.clear
        @pages.clear
        @unclaimed.clear
        @abandoned.clear
        taken
      end
      contexts.each(&.mark_closed)
      pages.each(&.dispose(reason))
      creations.each(&.cancellation.cancel(reason))
      unsubscribe
    end

    # Runs on the reader fiber. Creating the page here subscribes it to its
    # session before the session's first event is read.
    private def attached(event : Protocol::Browser::AttachedToTarget) : Nil
      context_id = event.target_info.browser_context_id
      context = context_id.try { |id| @lock.synchronize { @contexts[id]? } }
      # A target of a context this browser did not create, or removed.
      return unless context
      page = Page.new(@connection, event.session_id, event.target_info.target_id, context)
      outcome = register(page, awaited: event.target_info.opener_id.nil?)
      case outcome
      when PageCreation
        outcome.deliver(page)
      when Exception
        page.dispose(outcome)
      when Abandoned
        page.dispose(PageClosed.new("Page #{page.target_id} was discarded"))
        # The reader must not wait for the reply; the fiber ends within
        # CLEANUP_TIMEOUT.
        spawn(name: "crystalfaux-discard-page") { page.close_target(CLEANUP_TIMEOUT) }
      end
    end

    # Registers an attached *page*. Returns the creation waiting for it, the
    # reason to dispose it right away, `Abandoned` when its creation gave
    # up, or `nil`. An *awaited* page (one without an opener) is kept for
    # the creations in its context that do not know their target yet.
    private def register(page : Page, awaited : Bool) : (PageCreation | Exception | Abandoned)?
      target_id = page.target_id
      @lock.synchronize do
        return ConnectionClosed.new("Browser is closed") if @closed
        return PageClosed.new("Context #{page.context.id} is closed") if page.context.closed?
        return Abandoned.new if @abandoned.delete(target_id)
        @pages[target_id] = page
        creation = @creations.find(&.target_id.==(target_id))
        return creation if creation
        if awaited && @creations.any? { |pending| pending.context.same?(page.context) && pending.target_id.nil? }
          @unclaimed[target_id] = page
        end
        nil
      end
    end

    private def detached(event : Protocol::Browser::DetachedFromTarget) : Nil
      page = @lock.synchronize do
        # An unclaimed page stays in `@unclaimed`, closed, for its creation.
        @pages.delete(event.target_id) || @unclaimed[event.target_id]?
      end
      page.try &.dispose(PageClosed.new("Page #{event.target_id} was closed"))
    end
  end
end
