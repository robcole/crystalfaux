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
    @blocked_types = Set(ResourceType).new
    @blocked_urls = [] of Regex
    # Held while `Browser.setRequestInterception` is in flight, so that a
    # concurrent `#block` returns only after the browser confirmed it.
    @interception_lock = Sync::Mutex.new
    @intercepting = false

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

    # Whether `#close` ran, or the browser closed the context.
    def closed? : Bool
      @lock.synchronize { @closed }
    end

    # Aborts every request of the context's pages whose resource type is in
    # *types* or whose URL matches one of *urls*. A URL pattern is a
    # `Regex`, or a glob `String` that matches the whole URL, where `**`
    # matches any characters and `*` any characters except `/`. Rules add
    # up over calls.
    #
    # Turns on request interception for the context
    # (`Browser.setRequestInterception`) unless the browser already
    # confirmed it. When that fails, the error is raised and the rules stay;
    # they apply after a later call succeeds. Blocked requests fail with the
    # `blockedbyclient` error before `Page#on_request` handlers see them.
    #
    # ```
    # context.block(types: [Crystalfaux::ResourceType::Image], urls: ["**/analytics/**"])
    # ```
    def block(*, types : Enumerable(ResourceType) = [] of ResourceType, urls : Enumerable(U) = [] of String,
              timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil forall U
      patterns = urls.map { |url| url_pattern(url) }
      @lock.synchronize do
        @blocked_types.concat(types)
        @blocked_urls.concat(patterns)
      end
      @interception_lock.synchronize do
        return if @intercepting
        Protocol.call(@browser.connection, Protocol::Browser::SetRequestInterception.new(true, @id), timeout: timeout)
        @intercepting = true
      end
    end

    # Adds *headers* to every request of the context's pages, replacing the
    # headers of an earlier call.
    def set_extra_headers(headers : HTTP::Headers, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      request = Protocol::Browser::SetExtraHTTPHeaders.new(Protocol::Network::HTTPHeader.list(headers), @id)
      Protocol.call(@browser.connection, request, timeout: timeout)
    end

    # See `#set_extra_headers`.
    def extra_headers=(headers : HTTP::Headers) : HTTP::Headers
      set_extra_headers(headers)
      headers
    end

    # The cookies of the context, for every URL.
    def cookies(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Array(Cookie)
      Protocol.call(@browser.connection, Protocol::Browser::GetCookies.new(@id), timeout: timeout).cookies
    end

    # Adds or replaces *cookies* in the context.
    #
    # ```
    # context.set_cookies([Crystalfaux::CookieOptions.new("session", "abc", url: "https://example.com/")])
    # ```
    def set_cookies(cookies : Enumerable(CookieOptions), timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      Protocol.call(@browser.connection, Protocol::Browser::SetCookies.new(cookies.to_a, @id), timeout: timeout)
    end

    # Removes every cookie of the context.
    def clear_cookies(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      Protocol.call(@browser.connection, Protocol::Browser::ClearCookies.new(@id), timeout: timeout)
    end

    # Sends the context's requests through *proxy*
    # (`Browser.setContextProxy`). `Browser#new_context` calls it before it
    # returns the context. When the browser rejects the proxy, closes the
    # context and raises the error.
    protected def use_proxy(proxy : Proxy, timeout : Time::Span) : Nil
      request = Protocol::Browser::SetContextProxy.new(@id, proxy.type, proxy.host, proxy.port, proxy.bypass,
        proxy.username, proxy.password)
      Protocol.call(@browser.connection, request, timeout: timeout)
    rescue ex
      begin
        close(timeout)
      rescue Error
        # The context is forgotten anyway; the proxy error is the one to report.
      end
      raise ex
    end

    # Whether a `#block` rule matches *request*.
    protected def blocks?(request : Request) : Bool
      @lock.synchronize do
        @blocked_types.includes?(request.resource_type) || @blocked_urls.any?(&.matches?(request.url))
      end
    end

    private def url_pattern(pattern : Regex) : Regex
      pattern
    end

    private def url_pattern(glob : String) : Regex
      URLGlob.to_regex(glob)
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
