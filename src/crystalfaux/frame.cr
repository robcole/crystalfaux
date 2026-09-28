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
    # The Juggler frame id, for example `"mainframe-10"`.
    getter id : String

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
    # When the script returns a promise, the call waits for it. Values
    # become JSON:
    #
    # - `undefined` and `null` become `nil`. In the isolated world,
    #   `undefined` values in objects are left out, and in arrays become
    #   `nil`.
    # - `NaN`, `Infinity`, `-Infinity` and `-0` become floats.
    # - Objects and arrays keep their nesting. Functions and symbols
    #   become `nil`.
    # - A `Date` becomes `{}` in the isolated world and its ISO string in the
    #   main world; return `date.toISOString()` for the same value in both.
    #   A DOM node becomes `{}` in the isolated world and `"ref: <Node>"` in
    #   the main world. `Map`, `Set` and `RegExp` do not keep their contents
    #   in the isolated world.
    #
    # Raises `EvaluationError` with the message and stack when the script
    # throws or its promise rejects, and when the value holds a cycle or a
    # `BigInt`. Raises `ExecutionContextDestroyed` when the frame has no
    # execution context or loses it before the script returns, for example
    # during a navigation or after the frame was detached, and
    # `TimeoutError` after *timeout*.
    def evaluate(expression : String, world : World = :isolated,
                 timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : JSON::Any
      @page.evaluate_in(self, expression, world, Time.instant + timeout)
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
