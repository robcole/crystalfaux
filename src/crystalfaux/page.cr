module Crystalfaux
  # A browser tab: one Juggler page target with its own session.
  #
  # ```
  # page = context.new_page
  # page.goto("https://example.com/")
  # page.title                           # => "Example Domain"
  # page.evaluate("navigator.webdriver") # => false
  # page.close
  # ```
  #
  # The page keeps a live registry of its frames and of each frame's
  # execution contexts, built from the events of its session
  # (Playwright `server/firefox/ffPage.ts` does the same).
  #
  # Ownership and lifecycle:
  #
  # - `Browser` creates the page on the connection's reader fiber when
  #   `Browser.attachedToTarget` arrives, so the page subscribes to its
  #   session before the session's first event is read.
  # - The page owns those subscriptions. It removes them when it is closed:
  #   by `#close`, by `Context#close`, by `Browser#close`, when the browser
  #   detaches the target, or when the connection closes.
  # - A waiting call, such as `#goto`, registers a `Waiter` before it sends
  #   its request, so events that arrive before the reply count. Closing
  #   the page fails the waiter with the reason: `PageClosed`, or
  #   `ConnectionClosed` when the browser or its pipe closed.
  # - `Page.crashed` marks the page crashed: waiters and later calls raise
  #   `PageCrashed`. `#close` still works.
  class Page
    # The name of the isolated world whose execution contexts are tracked as
    # a frame's `utility_context_id`, as in Playwright
    # (`server/firefox/ffPage.ts`).
    UTILITY_WORLD = "__playwright_utility_world__"

    # Serializes the document with its doctype, as Playwright's
    # `Frame.content` does.
    CONTENT_SCRIPT = <<-JS
      (() => {
        let html = '';
        if (document.doctype) html = new XMLSerializer().serializeToString(document.doctype);
        if (document.documentElement) html += document.documentElement.outerHTML;
        return html;
      })()
      JS

    # The context the page belongs to.
    getter context : Context

    # The Juggler target id of the page.
    getter target_id : String

    @lock = Sync::Mutex.new
    @frames = {} of String => Frame
    @main_frame : Frame?
    # The frame of each tracked execution context.
    @context_frames = {} of String => Frame
    @ready = false
    @closing = false
    @closed = false
    @crashed = false
    @failure : Exception?
    @waiters = [] of Waiter
    @subscriptions = [] of Juggler::Subscription

    # :nodoc:
    #
    # Subscribes to the events of *session_id*. Call it on the reader fiber,
    # from the `Browser.attachedToTarget` handler.
    def initialize(@connection : Juggler::Connection, @session_id : String, @target_id : String, @context : Context)
      subscribe
    end

    # The top frame of the page.
    #
    # Raises `Error` before the browser has reported the frame; a page that
    # `Context#new_page` returns always has it.
    def main_frame : Frame
      @lock.synchronize { @main_frame } || raise Error.new("Page #{@target_id} has no main frame yet")
    end

    # The URL of the main frame's document.
    def url : String
      main_frame.url
    end

    # Navigates the main frame to *url* and returns after its `load` event.
    #
    # Raises `NavigationError` when the navigation is aborted, `TimeoutError`
    # when it does not load within *timeout*, `ProtocolError` when the
    # browser rejects the URL, and `PageCrashed`, `PageClosed` or
    # `ConnectionClosed` when the page goes away first. A navigation within
    # the same document returns without waiting.
    def goto(url : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      deadline = Time.instant + timeout
      frame_id = main_frame.id
      with_waiter do |waiter|
        navigation_id = call(Protocol::Page::Navigate.new(frame_id, url), deadline).navigation_id
        return unless navigation_id
        wait_for_load(waiter, frame_id, navigation_id, deadline, "Navigation to #{url}")
      end
    end

    # Evaluates *expression* in the main frame, in the page's own world, and
    # returns its value as JSON. `undefined` becomes JSON `null`; `NaN`,
    # `Infinity`, `-Infinity` and `-0` become floats.
    #
    # ```
    # page.evaluate("[screen.width, screen.height]") # => [1512, 982]
    # ```
    #
    # Raises `EvaluationError` when the script throws, and `Error` when the
    # main frame has no execution context, for example during a navigation.
    def evaluate(expression : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : JSON::Any
      deadline = Time.instant + timeout
      check_usable
      context_id = main_frame.main_context_id
      raise Error.new("The main frame of page #{@target_id} has no execution context") unless context_id
      outcome = call(Protocol::Runtime::Evaluate.new(context_id, expression, return_by_value: true), deadline)
      if details = outcome.exception_details
        message = details.text || details.value.try(&.to_json) || "The script threw"
        raise EvaluationError.new(message, details.stack)
      end
      value_of(outcome.result)
    end

    # The title of the main frame's document.
    def title(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String
      evaluate_string("document.title", timeout)
    end

    # The HTML of the main frame's document, with its doctype.
    def content(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String
      evaluate_string(CONTENT_SCRIPT, timeout)
    end

    # Closes the page. Safe to call more than once, and on a crashed page.
    #
    # Sends `Page.close`, then forgets the page even when that request
    # fails. Raises what the request raises, except `ConnectionClosed`.
    def close(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      return unless start_closing
      begin
        Protocol.call(@connection, Protocol::Page::Close.new, @session_id, timeout)
      rescue ConnectionClosed
        # The browser is gone, and the page with it.
      ensure
        @context.browser.remove_page(self, PageClosed.new("Page #{@target_id} is closed"))
      end
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    def crashed? : Bool
      @lock.synchronize { @crashed }
    end

    # Marks the page closed with *reason*: removes its subscriptions and
    # fails its waiters. Later calls raise *reason*. Safe to call more than
    # once; only the first reason counts.
    protected def dispose(reason : Exception) : Nil
      subscriptions, waiters = @lock.synchronize do
        return if @closed
        @closed = true
        @failure = reason
        {@subscriptions.dup.tap { @subscriptions.clear }, @waiters.dup}
      end
      subscriptions.each { |subscription| @connection.off(subscription) }
      waiters.each(&.fail(reason))
    end

    # Returns once the browser has sent `Page.ready`: the main frame and its
    # first document exist.
    protected def wait_until_ready(deadline : Time::Instant) : Nil
      with_waiter do |waiter|
        return if @lock.synchronize { @ready }
        waiter.wait(deadline, "Opening page #{@target_id}", &.is_a?(Protocol::Page::Ready))
      end
    end

    private def start_closing : Bool
      @lock.synchronize do
        return false if @closed || @closing
        @closing = true
      end
    end

    # Waits for the `load` of the document that navigation *navigation_id*
    # commits in *frame_id*. A `load` before that commit belongs to the
    # previous document.
    private def wait_for_load(waiter : Waiter, frame_id : String, navigation_id : String,
                              deadline : Time::Instant, description : String) : Nil
      committed = false
      waiter.wait(deadline, description) do |event|
        case event
        when Protocol::Page::NavigationCommitted
          committed ||= event.frame_id == frame_id && event.navigation_id == navigation_id
          false
        when Protocol::Page::NavigationAborted
          if event.frame_id == frame_id && event.navigation_id == navigation_id
            raise NavigationError.new("#{description} was aborted: #{event.error_text}")
          end
          false
        when Protocol::Page::EventFired
          committed && event.frame_id == frame_id && event.name.load?
        else
          false
        end
      end
    end

    private def evaluate_string(expression : String, timeout : Time::Span) : String
      value = evaluate(expression, timeout)
      value.as_s? || raise Error.new("Expected a string from #{expression.inspect}, got #{value.to_json}")
    end

    private def value_of(remote : Protocol::Runtime::RemoteObject?) : JSON::Any
      return JSON::Any.new(nil) unless remote
      if special = remote.unserializable_value
        return JSON::Any.new(
          case special
          in .infinity?          then Float64::INFINITY
          in .negative_infinity? then -Float64::INFINITY
          in .negative_zero?     then -0.0
          in .nan?               then Float64::NAN
          end
        )
      end
      remote.value || JSON::Any.new(nil)
    end

    # Registers a waiter for the block's duration. Raises the page's
    # failure first when the page is closed or crashed.
    private def with_waiter(& : Waiter ->)
      waiter = Waiter.new
      @lock.synchronize do
        raise_failure
        @waiters << waiter
      end
      yield waiter
    ensure
      @lock.synchronize { @waiters.delete(waiter) } if waiter
    end

    private def call(request : Protocol::Request(R), deadline : Time::Instant) : R forall R
      check_usable
      Protocol.call(@connection, request, @session_id, {deadline - Time.instant, Time::Span.zero}.max)
    end

    private def check_usable : Nil
      @lock.synchronize { raise_failure }
    end

    # Call with `@lock` held.
    private def raise_failure : Nil
      failure = @failure
      raise failure if failure
    end

    private def subscribe : Nil
      listen(Protocol::Page::FrameAttached) { |event| frame_attached(event) }
      listen(Protocol::Page::FrameDetached) { |event| frame_detached(event.frame_id) }
      listen(Protocol::Page::NavigationCommitted) do |event|
        update(event) { frame_for(event.frame_id).try &.url=(event.url) }
      end
      listen(Protocol::Page::SameDocumentNavigation) do |event|
        update { frame_for(event.frame_id).try &.url=(event.url) }
      end
      listen(Protocol::Page::NavigationAborted) { |event| update(event) { } }
      listen(Protocol::Page::EventFired) { |event| update(event) { } }
      listen(Protocol::Page::Ready) { |event| update(event) { @ready = true } }
      listen(Protocol::Page::Crashed) { crash }
      listen(Protocol::Runtime::ExecutionContextCreated) { |event| update { context_created(event) } }
      listen(Protocol::Runtime::ExecutionContextDestroyed) do |event|
        update { context_destroyed(event.execution_context_id) }
      end
      listen(Protocol::Runtime::ExecutionContextsCleared) { update { contexts_cleared } }
    end

    private def listen(type : T.class, &handler : T ->) : Nil forall T
      @subscriptions << @connection.on(T::METHOD, @session_id) do |params|
        handler.call(Protocol.decode(type, params))
      end
    end

    # Runs the block with `@lock` held, then hands *event* to every waiter.
    private def update(event : Waiter::Event? = nil, &) : Nil
      @lock.synchronize do
        yield
        @waiters.each(&.push(event)) if event
      end
    end

    # Call with `@lock` held.
    private def frame_for(frame_id : String?) : Frame?
      frame_id.try { |id| @frames[id]? }
    end

    private def frame_attached(event : Protocol::Page::FrameAttached) : Nil
      update do
        parent = frame_for(event.parent_frame_id)
        frame = Frame.new(event.frame_id, parent, @lock)
        @frames[frame.id] = frame
        if parent
          parent.add_child(frame)
        else
          @main_frame = frame
        end
      end
    end

    private def frame_detached(frame_id : String) : Nil
      update do
        frame = @frames[frame_id]?
        next unless frame
        frame.parent.try &.remove_child(frame)
        forget_frame(frame)
      end
    end

    # Call with `@lock` held. Forgets *frame*, its descendants and their
    # execution contexts.
    private def forget_frame(frame : Frame) : Nil
      @frames.delete(frame.id)
      @context_frames.reject! { |_, owner| owner.same?(frame) }
      frame.child_frames.each { |child| forget_frame(child) }
    end

    # Call with `@lock` held.
    private def context_created(event : Protocol::Runtime::ExecutionContextCreated) : Nil
      frame = frame_for(event.aux_data.frame_id)
      return unless frame
      case event.aux_data.name
      when nil, ""
        frame.main_context_id = event.execution_context_id
      when UTILITY_WORLD
        frame.utility_context_id = event.execution_context_id
      else
        # Another isolated world, such as an extension's; not tracked.
        return
      end
      @context_frames[event.execution_context_id] = frame
    end

    # Call with `@lock` held.
    private def context_destroyed(context_id : String) : Nil
      @context_frames.delete(context_id).try &.clear_context(context_id)
    end

    # Call with `@lock` held.
    private def contexts_cleared : Nil
      @frames.each_value(&.clear_contexts)
      @context_frames.clear
    end

    private def crash : Nil
      failure = PageCrashed.new("Page #{@target_id} crashed")
      waiters = @lock.synchronize do
        return if @closed
        @crashed = true
        @failure = failure
        @waiters.dup
      end
      waiters.each(&.fail(failure))
    end
  end
end
