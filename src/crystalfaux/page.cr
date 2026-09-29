# Portions of this file are translated to Crystal from Playwright
# (https://github.com/microsoft/playwright):
# - `packages/playwright-core/src/server/frames.ts` (`Frame.content`)
# - `packages/playwright-core/src/server/screenshotter.ts`
#
# Copyright 2017 Google Inc. Modifications copyright (c) Microsoft Corporation.
# Licensed under the Apache License, Version 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). See `NOTICE`.

require "base64"

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
  # execution context, built from the events of its session
  # (Playwright `server/firefox/ffPage.ts` does the same). It tracks only the
  # default world of each frame, which Camoufox makes an isolated sandbox;
  # other worlds, such as Playwright's `__playwright_utility_world__`, exist
  # only after an init script names them, and crystalfaux registers none.
  # A context is forgotten on `Runtime.executionContextDestroyed` (sent for
  # each navigation), `Runtime.executionContextsCleared` and frame detach.
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
  # - Requests the page sends carry the page's `Juggler::Cancellation`.
  #   Closing the page, or a crash, cancels it: a call that waits for its
  #   reply raises the reason at once, and the reply is dropped when it
  #   comes. Other pages on the connection are not affected.
  # - `Page.crashed` marks the page crashed: waiters, pending requests and
  #   later calls raise `PageCrashed`. `#close` still works.
  # - An evaluation registers its own `Juggler::Cancellation` under its
  #   execution context. When the page forgets the context, it cancels the
  #   evaluation with `ExecutionContextDestroyed`; closing the page, or a
  #   crash, cancels it with the reason, as for other requests.
  # - The page's `Traffic` follows its network events and runs
  #   `#on_request` and `#on_response` handlers in fibers of their own.
  #   Closing the page, or a crash, drops the handlers and fails
  #   `Response#body` waits with the reason. A handler that is running
  #   then is not stopped, but its request decisions raise the reason.
  class Page
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

    # The visible part of the document, where it is scrolled to.
    VIEWPORT_SCRIPT = "({x: window.scrollX, y: window.scrollY, width: window.innerWidth, height: window.innerHeight})"

    # The size of the whole document, as Playwright's
    # `server/screenshotter.ts` measures it.
    DOCUMENT_SCRIPT = <<-JS
      (() => {
        const body = document.body, root = document.documentElement;
        return {
          x: 0, y: 0,
          width: Math.max(body.scrollWidth, root.scrollWidth, body.offsetWidth, root.offsetWidth, body.clientWidth, root.clientWidth),
          height: Math.max(body.scrollHeight, root.scrollHeight, body.offsetHeight, root.offsetHeight, body.clientHeight, root.clientHeight),
        };
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
    # The cancellations of the running evaluations, by execution context.
    @evaluations = {} of String => Array(Juggler::Cancellation)
    @ready = false
    @closing = false
    @closed = false
    @crashed = false
    @failure : Exception?
    @waiters = [] of Waiter
    @subscriptions = [] of Juggler::Subscription
    @cancellation = Juggler::Cancellation.new
    @keyboard : Keyboard?
    @mouse : Mouse?
    @traffic = Traffic.new
    # Held while `Network.setRequestInterception` is in flight, so that a
    # concurrent `#on_request` returns only after the browser confirmed it.
    @interception_lock = Sync::Mutex.new
    @intercepting = false

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
    # Raises `NavigationError` when the navigation is aborted or another
    # navigation of the main frame commits before its `load`, `TimeoutError`
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

    # Evaluates *expression* in the main frame and returns its value as
    # JSON. See `Frame#evaluate` for *world*, the values and the errors.
    #
    # By default the script runs in Camoufox's isolated world: it sees the
    # DOM, but not the globals of the page's own scripts.
    #
    # ```
    # # The page ran <script>window.marker = 42</script>.
    # page.evaluate("[screen.width, screen.height]") # => [1512, 982]
    # page.evaluate("window.marker")                 # => nil
    # page.evaluate("window.marker", world: :main)   # => 42, with allowMainWorld
    # ```
    #
    # To read page state without the main world, read what the page
    # writes to the DOM, for example
    # `page.evaluate("document.querySelector('#state').textContent")`.
    def evaluate(expression : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT,
                 *, world : World = :isolated) : JSON::Any
      main_frame.evaluate(expression, timeout, world: world)
    end

    # Runs `Frame#evaluate` for *frame*, a frame of this page.
    protected def evaluate_in(frame : Frame, expression : String, world : World, deadline : Time::Instant) : JSON::Any
      context_id, cancellation = start_evaluation(frame)
      begin
        outcome = case world
                  in .isolated?
                    call(Protocol::Runtime::Evaluate.new(context_id, expression, return_by_value: true), deadline, cancellation)
                  in .main?
                    call(Protocol::Runtime::MainWorld.request(context_id, expression), deadline, cancellation)
                  end
      rescue ex : ProtocolError
        raise evaluation_failure(ex, frame)
      ensure
        finish_evaluation(context_id, cancellation)
      end
      if details = outcome.exception_details
        message = details.text || details.value.try(&.to_json) || "The script threw"
        raise EvaluationError.new(message, details.stack)
      end
      case world
      in .isolated? then value_of(outcome.result)
      in .main?     then Protocol::Runtime::MainWorld.decode(outcome.result.try(&.value))
      end
    end

    # The title of the main frame's document.
    def title(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String
      evaluate_string("document.title", timeout)
    end

    # The HTML of the main frame's document, with its doctype.
    def content(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String
      evaluate_string(CONTENT_SCRIPT, timeout)
    end

    # The keyboard of the page.
    def keyboard : Keyboard
      @lock.synchronize { @keyboard ||= Keyboard.new(self) }
    end

    # The mouse of the page. Its events carry the modifier keys that
    # `#keyboard` holds.
    def mouse : Mouse
      keyboard = self.keyboard
      @lock.synchronize { @mouse ||= Mouse.new(self, keyboard) }
    end

    # Takes a screenshot of the visible viewport and returns the image.
    #
    # With *full_page*, takes the whole document instead. *quality* (0 to
    # 100) is for JPEG and WebP only.
    #
    # ```
    # File.write("page.png", page.screenshot(full_page: true))
    # ```
    def screenshot(*, format : Protocol::Page::ImageType = :png, quality : Int32? = nil,
                   full_page : Bool = false, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Bytes
      deadline = Time.instant + timeout
      check_quality(format, quality)
      clip = evaluate_clip(full_page ? DOCUMENT_SCRIPT : VIEWPORT_SCRIPT, deadline)
      capture(format, quality, clip, deadline)
    end

    # Takes a screenshot of *clip*, a rectangle in CSS pixels from the
    # top-left corner of the document, and returns the image.
    #
    # ```
    # clip = Crystalfaux::Protocol::Page::Clip.new(0, 0, 400, 300)
    # page.screenshot(format: :jpeg, quality: 80, clip: clip)
    # ```
    def screenshot(*, clip : Protocol::Page::Clip, format : Protocol::Page::ImageType = :png,
                   quality : Int32? = nil, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Bytes
      check_quality(format, quality)
      capture(format, quality, clip, Time.instant + timeout)
    end

    # Sets the size of the viewport in CSS pixels.
    def set_viewport_size(width : Int32, height : Int32, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      size = Protocol::Page::Size.new(width.to_f, height.to_f)
      call(Protocol::Page::SetViewportSize.new(size), Time.instant + timeout)
    end

    # Sends one input event for `Keyboard` or `Mouse`.
    protected def dispatch(event : Protocol::Request(Protocol::Empty)) : Nil
      call(event, Time.instant + Browser::DEFAULT_TIMEOUT)
    end

    # Calls *handler* with each request of the page that the browser
    # intercepted, and turns on interception for the page unless the
    # browser already confirmed it. When that fails, the handler is not
    # added and the error is raised; a later call tries again.
    #
    # The handler decides the request with `Request#abort`,
    # `Request#continue` or `Request#fulfill`. Handlers run in the order
    # they were added until one decides; when none does, the page continues
    # the request. A request that a `Context#block` rule matches is aborted
    # before the handlers see it.
    #
    # Each request runs its handlers in a fiber of its own, so a handler
    # may call page methods, and several requests can be in their handlers
    # at once. An exception from a handler is logged.
    #
    # ```
    # page.on_request do |request|
    #   request.abort if request.url.includes?("/ads/")
    # end
    # ```
    def on_request(timeout : Time::Span = Browser::DEFAULT_TIMEOUT, &handler : Request ->) : Nil
      # Added first, so a request intercepted as soon as interception is on
      # already sees the handler.
      @traffic.add_request_handler(handler)
      begin
        enable_interception(timeout)
      rescue ex
        @traffic.remove_request_handler(handler)
        raise ex
      end
    end

    # Calls *handler* with each response the page receives, in a fiber per
    # response; see `Response#body`. An exception from a handler is logged.
    def on_response(&handler : Response ->) : Nil
      @traffic.add_response_handler(handler)
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

    # Whether the page is closed: by `#close`, by its context or browser,
    # or because the connection closed. A crashed page is not closed until
    # one of these happens.
    def closed? : Bool
      @lock.synchronize { @closed }
    end

    # Whether the browser reported that the page crashed (`Page.crashed`).
    def crashed? : Bool
      @lock.synchronize { @crashed }
    end

    # Marks the page closed with *reason*: removes its subscriptions, fails
    # its waiters and cancels its pending requests. Later calls raise
    # *reason*. Safe to call more than once; only the first reason counts.
    protected def dispose(reason : Exception) : Nil
      subscriptions, waiters = @lock.synchronize do
        return if @closed
        @closed = true
        @failure = reason
        {@subscriptions.dup.tap { @subscriptions.clear }, @waiters.dup}
      end
      subscriptions.each { |subscription| @connection.off(subscription) }
      waiters.each(&.fail(reason))
      @cancellation.cancel(reason)
      cancel_evaluations(reason)
      @traffic.dispose(reason)
    end

    # Sends `Page.close` for a page that `Browser` gave up on while opening
    # it, and waits at most *timeout*. Ignores failures: the context removes
    # the target when it closes. Does not change the page's state; dispose
    # the page first.
    protected def close_target(timeout : Time::Span) : Nil
      Protocol.call(@connection, Protocol::Page::Close.new, @session_id, timeout)
    rescue Error
      # Best effort; the original error matters to the caller.
    end

    # Returns once the browser has sent `Page.ready`: the main frame and its
    # first document exist.
    protected def wait_until_ready(deadline : Time::Instant) : Nil
      with_waiter do |waiter|
        return if @lock.synchronize { @ready }
        waiter.wait(deadline, "Opening page #{@target_id}", &.is_a?(Protocol::Page::Ready))
      end
    end

    private def enable_interception(timeout : Time::Span) : Nil
      @interception_lock.synchronize do
        return if @intercepting
        call(Protocol::Network::SetRequestInterception.new(true), Time.instant + timeout)
        @intercepting = true
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
    # previous document. A later commit of another navigation replaces the
    # document before it loads, as Playwright treats an interrupted
    # navigation.
    private def wait_for_load(waiter : Waiter, frame_id : String, navigation_id : String,
                              deadline : Time::Instant, description : String) : Nil
      committed = false
      waiter.wait(deadline, description) do |event|
        case event
        when Protocol::Page::NavigationCommitted
          next false unless event.frame_id == frame_id
          if committed
            raise NavigationError.new("#{description} was replaced by navigation to #{event.url} before it loaded")
          end
          committed = event.navigation_id == navigation_id
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

    private def evaluate_clip(script : String, deadline : Time::Instant) : Protocol::Page::Clip
      value = evaluate(script, timeout: {deadline - Time.instant, Time::Span.zero}.max)
      Protocol.decode(Protocol::Page::Clip, value)
    end

    private def check_quality(format : Protocol::Page::ImageType, quality : Int32?) : Nil
      return unless quality
      raise ArgumentError.new("A #{format.wire_name} screenshot takes no quality") if format.png?
      raise ArgumentError.new("Screenshot quality must be 0 to 100, not #{quality}") unless 0 <= quality <= 100
    end

    # Takes the screenshot of *clip*, in document coordinates.
    private def capture(format : Protocol::Page::ImageType, quality : Int32?, clip : Protocol::Page::Clip,
                        deadline : Time::Instant) : Bytes
      data = call(Protocol::Page::Screenshot.new(format, clip, quality: quality), deadline).data
      Base64.decode(data)
    end

    # Registers an evaluation in *frame*'s execution context and returns
    # the context and the evaluation's cancellation. Raises the page's
    # failure, or `ExecutionContextDestroyed` when the frame has no context.
    private def start_evaluation(frame : Frame) : {String, Juggler::Cancellation}
      @lock.synchronize do
        raise_failure
        context_id = @context_frames.key_for?(frame)
        raise ExecutionContextDestroyed.new("Frame #{frame.id} has no execution context") unless context_id
        cancellation = Juggler::Cancellation.new
        (@evaluations[context_id] ||= [] of Juggler::Cancellation) << cancellation
        {context_id, cancellation}
      end
    end

    private def finish_evaluation(context_id : String, cancellation : Juggler::Cancellation) : Nil
      @lock.synchronize do
        cancellations = @evaluations[context_id]?
        next unless cancellations
        cancellations.delete(cancellation)
        @evaluations.delete(context_id) if cancellations.empty?
      end
    end

    private def cancel_evaluations(reason : Exception) : Nil
      cancellations = @lock.synchronize { @evaluations.values.flatten.tap { @evaluations.clear } }
      cancellations.each(&.cancel(reason))
    end

    # Translates a protocol error from an evaluation in *frame*. Camoufox
    # `additions/juggler/content/Runtime.js` fails a pending evaluation with
    # "Execution context was destroyed!" when a navigation or detach
    # destroys its context, and "Failed to find execution context" when the
    # context is gone before the request arrives. `ExecutionContext#_serialize`
    # fails with "Object is not serializable" for a cycle, and JSON fails
    # with "can't be serialized" for a `BigInt`.
    private def evaluation_failure(error : ProtocolError, frame : Frame) : Error
      reason = error.message.to_s
      if reason.includes?("Execution context was destroyed") || reason.includes?("Failed to find execution context")
        context_lost(frame)
      elsif reason.includes?("not serializable") || reason.includes?("can't be serialized")
        EvaluationError.new("The result is not serializable as JSON: #{reason}")
      else
        error
      end
    end

    private def evaluate_string(expression : String, timeout : Time::Span) : String
      value = evaluate(expression, timeout: timeout)
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

    # Sends *request* to the page's session. `Request` and `Response` use it.
    # An evaluation passes its own *cancellation*.
    protected def call(request : Protocol::Request(R), deadline : Time::Instant,
                       cancellation : Juggler::Cancellation = @cancellation) : R forall R
      check_usable
      Protocol.call(@connection, request, @session_id, {deadline - Time.instant, Time::Span.zero}.max, cancellation)
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
      listen(Protocol::Network::RequestWillBeSent) { |event| @traffic.request_will_be_sent(self, event) }
      listen(Protocol::Network::ResponseReceived) { |event| @traffic.response_received(event) }
      listen(Protocol::Network::RequestFinished) { |event| @traffic.request_finished(event.request_id) }
      listen(Protocol::Network::RequestFailed) { |event| @traffic.request_failed(event) }
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
        frame = Frame.new(self, event.frame_id, parent, @lock)
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
      @context_frames.select { |_, owner| owner.same?(frame) }.each_key { |context_id| context_destroyed(context_id) }
      frame.child_frames.each { |child| forget_frame(child) }
    end

    # Call with `@lock` held. Tracks the default world only: its name is
    # empty. Other worlds, such as an extension's, are not tracked.
    private def context_created(event : Protocol::Runtime::ExecutionContextCreated) : Nil
      frame = frame_for(event.aux_data.frame_id)
      return unless frame && event.aux_data.name.presence.nil?
      frame.default_context_id = event.execution_context_id
      @context_frames[event.execution_context_id] = frame
    end

    # Call with `@lock` held. Forgets *context_id* and fails the
    # evaluations that run in it.
    private def context_destroyed(context_id : String) : Nil
      frame = @context_frames.delete(context_id)
      return unless frame
      frame.clear_context(context_id)
      @evaluations.delete(context_id).try &.each(&.cancel(context_lost(frame)))
    end

    # Call with `@lock` held.
    private def contexts_cleared : Nil
      @context_frames.keys.each { |context_id| context_destroyed(context_id) }
      @frames.each_value(&.clear_contexts)
    end

    private def context_lost(frame : Frame) : ExecutionContextDestroyed
      ExecutionContextDestroyed.new("The execution context of frame #{frame.id} was destroyed")
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
      @cancellation.cancel(failure)
      cancel_evaluations(failure)
      @traffic.dispose(failure)
    end
  end
end
