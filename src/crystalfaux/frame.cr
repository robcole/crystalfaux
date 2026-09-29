module Crystalfaux
  # A frame of a `Page`: the main frame or an `<iframe>`.
  #
  # ```
  # frame = page.main_frame
  # frame.url      # => "https://example.com/"
  # frame.parent   # => nil
  # frame.children # => [#<Crystalfaux::Frame ...>]
  # ```
  #
  # A frame is live: its page updates it from the browser's events on the
  # connection's reader fiber, under the page's lock. A frame that was
  # detached keeps its last state.
  class Frame
    # How often `#wait_for_function` and `#wait_for_selector` evaluate.
    POLLING = 100.milliseconds

    # The Juggler frame id, for example `"mainframe-10"`.
    getter id : String

    # The page the frame belongs to.
    getter page : Page

    # The parent frame, or `nil` for the main frame.
    getter parent : Frame?

    @url = ""
    @children = [] of Frame
    @default_context_id : String?

    # :nodoc:
    def initialize(@page : Page, @id : String, @parent : Frame?, @lock : Sync::Mutex)
    end

    # The URL of the frame's document; empty until its first navigation
    # commits.
    def url : String
      @lock.synchronize { @url }
    end

    # The frames inside this frame, in the order they were attached.
    def children : Array(Frame)
      @lock.synchronize { @children.dup }
    end

    # Evaluates *expression* in this frame and returns its value as JSON.
    #
    # ```
    # frame.evaluate("document.title")              # => "Example Domain"
    # frame.evaluate("window.marker")               # => nil
    # frame.evaluate("window.marker", world: :main) # => 42
    # ```
    #
    # *world* selects where the script runs (see `World`):
    #
    # - `World::Isolated` (the default) is Camoufox's sandbox. It sees the
    #   DOM, but not the globals of the page's own scripts.
    # - `World::Main` is the world of the page's scripts. It needs the launch
    #   config key `allowMainWorld` set to `true`; without it, the call
    #   raises `EvaluationError`.
    #
    # When the script returns a promise, the call waits for it, with one
    # exception: in the isolated world, a promise that a page API makes,
    # such as the one `fetch()` returns, never settles, and the call raises
    # `TimeoutError`. Wrap it in a promise that the script makes, or use
    # `World::Main`:
    #
    # ```
    # frame.evaluate("fetch('/api').then(r => r.text())") # raises TimeoutError
    # frame.evaluate("new Promise((resolve, reject) => fetch('/api').then(r => r.text()).then(resolve, reject))")
    # frame.evaluate("fetch('/api').then(r => r.text())", world: :main) # with allowMainWorld
    # ```
    #
    # Both worlds
    # return `undefined` and `null` as `nil`, and a top-level `NaN`,
    # `Infinity`, `-Infinity` or `-0` as a float. Inside objects and arrays
    # the worlds differ:
    #
    # | Value inside an object or array | Isolated world                      | Main world |
    # | ------------------------------- | ----------------------------------- | ---------- |
    # | `NaN`, `Infinity`, `-Infinity`  | `nil`                               | float      |
    # | `-0`                            | `0`                                 | `-0.0`     |
    # | `undefined`, function           | omitted in objects, `nil` in arrays | `nil`      |
    # | symbol                          | the whole result becomes `nil`      | `nil`      |
    #
    # The isolated world serializes with `JSON.stringify` (Camoufox
    # `additions/juggler/content/Runtime.js`, `_serialize`); the main world
    # with Playwright's serializer, see `Protocol::Runtime::MainWorld`. A
    # `Date` becomes `{}` in the isolated world and its ISO string in the
    # main world; return `date.toISOString()` for the same value in both. A
    # DOM node becomes `{}` in the isolated world and `"ref: <Node>"` in the
    # main world. `Map`, `Set` and `RegExp` do not keep their contents in the
    # isolated world.
    #
    # Raises `EvaluationError` with the message and stack when the script
    # throws or its promise rejects, and when the value holds a cycle or a
    # `BigInt`. Raises `ExecutionContextDestroyed` when the frame has no
    # execution context or loses it before the script returns, for example
    # during a navigation or after the frame was detached, and
    # `TimeoutError` after *timeout*.
    def evaluate(expression : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT,
                 *, world : World = :isolated) : JSON::Any
      @page.evaluate_in(self, expression, world, Time.instant + timeout)
    end

    # Returns the first element that CSS *selector* matches in this frame's
    # document, or `nil`.
    #
    # ```
    # button = frame.query_selector("button.add-to-cart")
    # button.try &.click
    # ```
    #
    # The handle belongs to the frame's current document; see
    # `ElementHandle` for how long it lives. Raises `EvaluationError` for an
    # invalid selector and `ExecutionContextDestroyed` when the frame has no
    # document.
    def query_selector(selector : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : ElementHandle?
      context_id = current_context_id
      remote = call_function(context_id, DomScripts::QUERY, [argument(selector)], Time.instant + timeout, by_value: false)
      element_for(context_id, remote)
    end

    # Returns every element that CSS *selector* matches in this frame's
    # document, in document order. Raises as `#query_selector` does.
    def query_selector_all(selector : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Array(ElementHandle)
      deadline = Time.instant + timeout
      context_id = current_context_id
      remote = call_function(context_id, DomScripts::QUERY_ALL, [argument(selector)], deadline, by_value: false)
      elements_for(context_id, remote, deadline)
    end

    # Evaluates *expression* every *polling* until its value is truthy in
    # JavaScript, and returns that value.
    #
    # ```
    # frame.wait_for_function("document.querySelectorAll('.sku-item').length >= 24")
    # ```
    #
    # A navigation does not end the wait: while the frame has no document,
    # or when the document is replaced during an evaluation, the wait goes
    # on in the next document. *world* is as for `#evaluate`.
    #
    # Raises `TimeoutError` when the value is not truthy after *timeout*,
    # and `EvaluationError` at once when the script throws.
    def wait_for_function(expression : String, timeout : Time::Span = Browser::DEFAULT_TIMEOUT, *,
                          polling : Time::Span = POLLING, world : World = :isolated) : JSON::Any
      poll("Waiting for #{expression.inspect}", timeout, polling) do |deadline|
        value = @page.evaluate_in(self, expression, world, deadline)
        value if truthy?(value)
      end
    end

    # Waits until the first element that CSS *selector* matches is in
    # *state*, and returns it for `ElementState::Attached` and
    # `ElementState::Visible`; returns `nil` for `ElementState::Hidden` and
    # `ElementState::Detached`.
    #
    # ```
    # dialog = frame.wait_for_selector("[role=dialog]") # visible
    # frame.wait_for_selector("[role=dialog]", state: :hidden)
    # ```
    #
    # Checks every `POLLING`, and goes on through navigations as
    # `#wait_for_function` does. Raises `TimeoutError` after *timeout*.
    def wait_for_selector(selector : String, *, state : ElementState = :visible,
                          timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : ElementHandle?
      arguments = [argument(selector), argument(state.script_name)]
      found = poll("Waiting for #{selector.inspect} to be #{state.script_name}", timeout, POLLING) do |deadline|
        context_id = current_context_id
        remote = call_function(context_id, DomScripts::WAIT_FOR_SELECTOR, arguments, deadline, by_value: false)
        element_for(context_id, remote) || (remote.try(&.value).try(&.as_bool?) || nil)
      end
      found if found.is_a?(ElementHandle)
    end

    # Returns the elements of this frame with ARIA *role*, for example
    # `"button"`, and, when *name* is given, that accessible name. With
    # *exact* the name must be equal, ignoring extra whitespace; without
    # it, the name must contain *name*, ignoring case.
    #
    # ```
    # frame.get_by_role("button", name: "Add to Cart").first?.try &.click
    # frame.get_by_role("dialog").empty? # => true when no dialog is open
    # ```
    #
    # Hidden elements are left out. This is a small part of Playwright's
    # `getByRole`; `DomScripts::BY_ROLE` lists what it does not do.
    def get_by_role(role : String, *, name : String? = nil, exact : Bool = true,
                    timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Array(ElementHandle)
      deadline = Time.instant + timeout
      context_id = current_context_id
      arguments = [argument(role), argument(name), argument(exact)]
      remote = call_function(context_id, DomScripts::BY_ROLE, arguments, deadline, by_value: false)
      elements_for(context_id, remote, deadline)
    end

    # Calls *function* with *arguments* in execution context *context_id*
    # of this frame. Returns its value, or a handle unless *by_value*.
    protected def call_function(context_id : String, function : String, arguments : Array(Protocol::Runtime::CallFunctionArgument),
                                deadline : Time::Instant, *, by_value : Bool) : Protocol::Runtime::RemoteObject?
      request = Protocol::Runtime::CallFunction.new(context_id, function, arguments, return_by_value: by_value)
      @page.script_result(@page.call_in_context(self, context_id, request, deadline))
    end

    # The element that *remote* holds, or `nil` when it is not a node.
    protected def element_for(context_id : String, remote : Protocol::Runtime::RemoteObject?) : ElementHandle?
      return unless remote && remote.subtype.try(&.node?)
      remote.object_id.try { |object_id| ElementHandle.new(self, context_id, object_id) }
    end

    # The elements of the array handle *remote*, in order. Releases the
    # array handle; the element handles belong to the caller.
    protected def elements_for(context_id : String, remote : Protocol::Runtime::RemoteObject?,
                               deadline : Time::Instant) : Array(ElementHandle)
      list_id = remote.try(&.object_id)
      return [] of ElementHandle unless list_id
      begin
        request = Protocol::Runtime::GetObjectProperties.new(context_id, list_id)
        properties = @page.call_in_context(self, context_id, request, deadline).properties
      ensure
        release(context_id, list_id, deadline)
      end
      properties.sort_by(&.name.to_i).compact_map { |property| element_for(context_id, property.value) }
    end

    # A `Runtime.callFunction` argument that holds *value* as JSON.
    protected def argument(value : (String | Bool | Float64)?) : Protocol::Runtime::CallFunctionArgument
      Protocol::Runtime::CallFunctionArgument.new(value: JSON::Any.new(value))
    end

    # Checks that a click at (*x*, *y*) in this frame's viewport passes
    # through the `<iframe>` of each ancestor frame, as Playwright's
    # `server/dom.ts` (`_checkFrameIsHitTarget`) does: an element of a
    # parent document can cover the frame. Returns `"done"`, or the check
    # that failed.
    protected def check_hit_path(x : Float64, y : Float64, deadline : Time::Instant) : String
      frame = self
      while parent = frame.parent
        result = parent.hit_test_child(frame, x, y, deadline)
        return "done" if result["transformed"]?
        verdict = result["result"]?.try(&.as_s?) || "the frame check returned nothing"
        return verdict unless verdict == "done"
        x, y = coordinate(result["x"]?), coordinate(result["y"]?)
        frame = parent
      end
      "done"
    end

    # A coordinate that a script returned. `JSON.stringify` writes whole
    # numbers without a fraction, so they decode as integers.
    protected def coordinate(value : JSON::Any?) : Float64
      raw = value.try(&.raw)
      case raw
      when Float64 then raw
      when Int64   then raw.to_f
      else              raise Error.new("Expected a coordinate, got #{value.to_json}")
      end
    end

    # Runs `DomScripts::FRAME_HIT_TARGET` in this frame for the `<iframe>`
    # of *child*, and releases the handle to that element.
    protected def hit_test_child(child : Frame, x : Float64, y : Float64, deadline : Time::Instant) : JSON::Any
      context_id = current_context_id
      request = Protocol::Page::AdoptNode.new(child.id, context_id)
      owner = @page.call_in_context(self, context_id, request, deadline).remote_object
      owner_id = owner.try(&.object_id)
      return JSON.parse(%({"result":"the frame's element is not reachable"})) unless owner_id
      begin
        arguments = [Protocol::Runtime::CallFunctionArgument.new(object_id: owner_id), argument(x), argument(y)]
        @page.value_of(call_function(context_id, DomScripts::FRAME_HIT_TARGET, arguments, deadline, by_value: true))
      ensure
        release(context_id, owner_id, deadline)
      end
    end

    # Releases the handle *object_id*. Best effort: when the context is
    # gone, the browser released it already.
    private def release(context_id : String, object_id : String, deadline : Time::Instant) : Nil
      @page.call_in_context(self, context_id, Protocol::Runtime::DisposeObject.new(context_id, object_id), deadline)
    rescue Error
      # The caller's own call reports what went wrong.
    end

    # See `Page#context_id_for`.
    protected def current_context_id : String
      @page.context_id_for(self)
    end

    # Yields the deadline every *interval* until the block returns a value
    # other than `nil`, and returns it. A try that loses its execution
    # context counts as `nil`. Raises `TimeoutError` with *description*
    # after *timeout*.
    private def poll(description : String, timeout : Time::Span, interval : Time::Span, &)
      deadline = Time.instant + timeout
      loop do
        begin
          result = yield deadline
          return result unless result.nil?
        rescue ExecutionContextDestroyed
          # Between documents; try again in the next one.
        rescue TimeoutError
          break
        end
        remaining = deadline - Time.instant
        break unless remaining.positive?
        sleep({interval, remaining}.min)
      end
      raise TimeoutError.new("#{description} timed out after #{timeout}")
    end

    # JavaScript truthiness of a JSON value.
    private def truthy?(value : JSON::Any) : Bool
      case raw = value.raw
      when Nil     then false
      when Bool    then raw
      when Int64   then raw != 0
      when Float64 then !(raw == 0 || raw.nan?)
      when String  then !raw.empty?
      else              true
      end
    end

    # :nodoc:
    #
    # The execution context of this frame's default world, which Camoufox
    # makes the isolated sandbox (`additions/juggler/content/FrameTree.js`,
    # `_createIsolatedContext`). Main-world requests go through it too.
    # `nil` between documents and after the frame was detached.
    def default_context_id : String?
      @lock.synchronize { @default_context_id }
    end

    # The methods below change the frame. `Page` calls them with the lock
    # held.

    protected def url=(@url : String) : String
    end

    protected def add_child(frame : Frame) : Nil
      @children << frame
    end

    protected def remove_child(frame : Frame) : Nil
      @children.delete(frame)
    end

    protected def child_frames : Array(Frame)
      @children
    end

    protected def default_context_id=(@default_context_id : String?) : String?
    end

    # Forgets *context_id* if it is this frame's context.
    protected def clear_context(context_id : String) : Nil
      @default_context_id = nil if @default_context_id == context_id
    end

    protected def clear_contexts : Nil
      @default_context_id = nil
    end
  end
end
