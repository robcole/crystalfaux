# Portions of this file are translated to Crystal from Playwright
# (https://github.com/microsoft/playwright):
# - `packages/playwright-core/src/server/dom.ts` (`_retryAction`,
#   `_retryPointerAction`, `_clickablePoint`)
#
# Copyright (c) Microsoft Corporation.
# Licensed under the Apache License, Version 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). See `NOTICE`.

module Crystalfaux
  # A reference to one element of a frame's document.
  #
  # ```
  # if item = page.wait_for_selector(".sku-item")
  #   item.scroll_into_view_if_needed
  #   item.text_content # => "Laptop ..."
  #   item.query_selector("a").try &.get_attribute("href")
  #   item.click
  # end
  # ```
  #
  # `Frame#query_selector`, `Frame#wait_for_selector`, `Frame#get_by_role`
  # and the same methods of `Page` make handles. A handle is bound to the
  # execution context of the document it was found in: the default world of
  # its frame, which Camoufox makes an isolated sandbox. Its scripts see the
  # DOM, not the page's globals, and cannot run in the main world (Camoufox
  # `additions/juggler/content/Runtime.js` refuses handles there).
  #
  # Lifetime and ownership:
  #
  # - The caller owns each handle. A handle keeps its node alive in the
  #   page until `#dispose` or until its context is destroyed.
  # - A navigation, a detached frame, or a closed page destroys the context.
  #   The browser then releases every handle of the context, and later
  #   calls on the handle raise `ExecutionContextDestroyed`, or the page's
  #   failure. `#dispose` is then not needed.
  # - A node that the page removed from its document, for example when it
  #   re-rendered a list, stays readable, but actions that need layout,
  #   such as `#click` and `#scroll_into_view_if_needed`, raise
  #   `ElementDetached`. Query the element again.
  #
  # Use a handle from one fiber at a time.
  class ElementHandle
    # The waits between the tries of an action, as Playwright's
    # `server/dom.ts` (`_retryAction`); the last one repeats.
    RETRY_WAITS = [20, 100, 100, 500].map(&.milliseconds)

    # What Camoufox `additions/juggler/content/PageAgent.js` replies for a
    # node outside its document, and for one without a layout box
    # (`_scrollIntoViewIfNeeded`).
    DETACHED_REASON  = "Node is detached from document"
    NO_LAYOUT_REASON = "Node does not have a layout object"
    # What Camoufox `additions/juggler/content/FrameTree.js` replies for an
    # object id that no context of the frame has (`unsafeObject`).
    UNKNOWN_OBJECT_REASON = "Cannot find object with id"

    # The frame whose document holds the element.
    getter frame : Frame

    # The Juggler `objectId` of the element.
    getter remote_object_id : String

    @disposed = Atomic(Bool).new(false)

    # :nodoc:
    def initialize(@frame : Frame, @context_id : String, @remote_object_id : String)
    end

    # Calls *function* with the element as its first argument and *args*,
    # each as JSON, after it, and returns its value as JSON (see
    # `Frame#evaluate` for the values of the isolated world).
    #
    # ```
    # link.evaluate("(el, name) => el.dataset[name]", "sku") # => "6571366"
    # ```
    #
    # Raises `EvaluationError` when the function throws, and
    # `ExecutionContextDestroyed` when the handle's document is gone.
    def evaluate(function : String, *args, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : JSON::Any
      arguments = [self_argument]
      args.each { |arg| arguments << Protocol::Runtime::CallFunctionArgument.new(value: JSON.parse(arg.to_json)) }
      run(function, arguments, Time.instant + timeout)
    end

    # The element's `textContent`: the text of all descendants, hidden ones
    # too, as it is in the source.
    def text_content(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String?
      evaluate(DomScripts::TEXT_CONTENT, timeout: timeout).as_s?
    end

    # The element's `innerText`: the rendered text, as a user sees it.
    # Raises `EvaluationError` for an element that is not an HTML element.
    def inner_text(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String
      value = evaluate(DomScripts::INNER_TEXT, timeout: timeout)
      value.as_s? || raise Error.new("Expected a string from innerText, got #{value.to_json}")
    end

    # The value of attribute *name*, or `nil` when the element has none.
    def get_attribute(name : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String?
      evaluate(DomScripts::ATTRIBUTE, name, timeout: timeout).as_s?
    end

    # Whether the element is visible, as Playwright decides it: in the
    # document, rendered, `visibility: visible`, and with a non-empty box.
    # It can be outside the viewport.
    def visible?(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Bool
      evaluate(DomScripts::VISIBLE, timeout: timeout).as_bool? || false
    end

    # Returns the query result for CSS *selector* in the element's subtree,
    # as `Frame#query_selector` does for the document.
    def query_selector(selector : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : ElementHandle?
      arguments = [self_argument, @frame.argument(selector)]
      @frame.element_for(@context_id, handle_call(DomScripts::QUERY_UNDER, arguments, Time.instant + timeout))
    end

    # Returns every element in the element's subtree that CSS *selector*
    # matches, in document order.
    def query_selector_all(selector : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Array(ElementHandle)
      deadline = Time.instant + timeout
      arguments = [self_argument, @frame.argument(selector)]
      @frame.elements_for(@context_id, handle_call(DomScripts::QUERY_ALL_UNDER, arguments, deadline), deadline)
    end

    # The smallest rectangle around the element's border boxes, in CSS
    # pixels from the top-left corner of the page's viewport, from
    # `Page.getContentQuads`. `nil` when the element is not rendered.
    def bounding_box(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Protocol::Page::Rect?
      quads = content_quads(Time.instant + timeout)
      return if quads.empty?
      points = quads.flat_map(&.points.to_a)
      left, right = points.minmax_of(&.x)
      top, bottom = points.minmax_of(&.y)
      Protocol::Page::Rect.new(left, top, right - left, bottom - top)
    end

    # Scrolls the element into view unless it is fully visible already,
    # with `Page.scrollIntoViewIfNeeded`.
    #
    # Raises `ElementDetached` when the node left its document, and `Error`
    # when it is not rendered.
    def scroll_into_view_if_needed(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      reason = scroll(Time.instant + timeout)
      raise Error.new("Cannot scroll the element into view: #{reason}") if reason
    end

    # Clicks the centre of the element with a trusted mouse click, after
    # Playwright's actionability checks (`server/dom.ts`,
    # `_retryPointerAction`): the element is attached, visible, and stable
    # (the same box in two animation frames in a row); it is then scrolled
    # into view, and it must receive a click at its centre, that is, no
    # other element covers it.
    #
    # ```
    # page.get_by_role("button", name: "Close").first.click
    # ```
    #
    # A check that fails is tried again, until *timeout*. Raises
    # `TimeoutError` that names the last failed check, for example
    # `covered by <div id="cover">`, and `ElementDetached` at once when the
    # node left its document.
    def click(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      deadline = Time.instant + timeout
      reason = "no check finished"
      RETRY_WAITS.each.chain(Iterator.of(RETRY_WAITS.last)).each do |wait|
        begin
          failed = try_click(deadline)
        rescue TimeoutError
          break
        end
        return unless failed
        reason = failed
        remaining = deadline - Time.instant
        break unless remaining.positive?
        sleep({wait, remaining}.min)
      end
      raise TimeoutError.new("Clicking the element timed out after #{timeout}: #{reason}")
    end

    # Releases the handle in the page. Safe to call more than once; later
    # calls on the handle raise `Error`. Does nothing more when the
    # handle's context or page is gone: the browser released the handle
    # with it.
    def dispose(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      return if @disposed.swap(true)
      request = Protocol::Runtime::DisposeObject.new(@context_id, @remote_object_id)
      @frame.page.call_in_context(@frame, @context_id, request, Time.instant + timeout)
    rescue ExecutionContextDestroyed | PageClosed | PageCrashed | ConnectionClosed
      # The browser released the handle with its context or page.
    end

    # One try of `#click`: returns `nil` after the click, or the check that
    # failed.
    private def try_click(deadline : Time::Instant) : String?
      state = run(DomScripts::ACTIONABLE, [self_argument], deadline).as_s?
      return failed_check(state) unless state == "done"
      if reason = scroll(deadline)
        return reason
      end
      point = click_point(content_quads(deadline))
      return "element is not visible" unless point
      x, y = point
      if reason = hit_path_failure(x, y, deadline)
        return reason
      end
      @frame.page.mouse.click(x, y, timeout: deadline - Time.instant)
      nil
    end

    # Hit-tests the element in its frame, then the frame in each ancestor
    # at (*x*, *y*), the click point in the main frame's viewport. Returns
    # `nil` when a click reaches the element, or the failed check.
    private def hit_path_failure(x : Float64, y : Float64, deadline : Time::Instant) : String?
      target = run(DomScripts::HIT_TARGET, [self_argument], deadline).as_s?
      return failed_check(target) unless target == "done"
      path = @frame.check_hit_path(x, y, deadline)
      failed_check(path) unless path == "done"
    end

    # The reason for a script result other than `"done"`. Raises
    # `ElementDetached` for `"notconnected"`.
    private def failed_check(result : String?) : String
      raise detached if result == "notconnected"
      result || "the check returned nothing"
    end

    # The centre of the first quad with an area, as Playwright's
    # `_clickablePoint` picks it. Quads under one pixel square do not count.
    private def click_point(quads : Array(Protocol::Page::Quad)) : {Float64, Float64}?
      quad = quads.find { |candidate| area(candidate) > 0.99 }
      return unless quad
      points = quad.points
      {points.sum(&.x) / 4, points.sum(&.y) / 4}
    end

    private def area(quad : Protocol::Page::Quad) : Float64
      points = quad.points
      doubled = (0...4).sum do |index|
        from, to = points[index], points[(index + 1) % 4]
        from.x * to.y - to.x * from.y
      end
      doubled.abs / 2
    end

    # Scrolls the element into view. Returns `nil`, or why the element
    # cannot be scrolled to.
    private def scroll(deadline : Time::Instant) : String?
      page_call(Protocol::Page::ScrollIntoViewIfNeeded.new(@frame.id, @remote_object_id), deadline)
      nil
    rescue ex : ProtocolError
      raise ex unless ex.message.to_s.includes?(NO_LAYOUT_REASON)
      "element is not visible"
    end

    private def content_quads(deadline : Time::Instant) : Array(Protocol::Page::Quad)
      page_call(Protocol::Page::GetContentQuads.new(@frame.id, @remote_object_id), deadline).quads
    end

    # Calls *function* and returns its value.
    private def run(function : String, arguments : Array(Protocol::Runtime::CallFunctionArgument),
                    deadline : Time::Instant) : JSON::Any
      check_disposed
      @frame.page.value_of(@frame.call_function(@context_id, function, arguments, deadline, by_value: true))
    end

    # Calls *function* and returns its result as a handle.
    private def handle_call(function : String, arguments : Array(Protocol::Runtime::CallFunctionArgument),
                            deadline : Time::Instant) : Protocol::Runtime::RemoteObject?
      check_disposed
      @frame.call_function(@context_id, function, arguments, deadline, by_value: false)
    end

    # Sends a `Page` request about the element. Translates the replies for
    # a detached node and an unknown object.
    private def page_call(request : Protocol::Request(R), deadline : Time::Instant) : R forall R
      check_disposed
      @frame.page.call_in_context(@frame, @context_id, request, deadline)
    rescue ex : ProtocolError
      reason = ex.message.to_s
      raise detached if reason.includes?(DETACHED_REASON)
      raise ExecutionContextDestroyed.new("The element's execution context was destroyed") if reason.includes?(UNKNOWN_OBJECT_REASON)
      raise ex
    end

    private def self_argument : Protocol::Runtime::CallFunctionArgument
      Protocol::Runtime::CallFunctionArgument.new(object_id: @remote_object_id)
    end

    private def check_disposed : Nil
      raise Error.new("The element handle is disposed") if @disposed.get
    end

    private def detached : ElementDetached
      ElementDetached.new("The element is not attached to the document")
    end
  end
end
