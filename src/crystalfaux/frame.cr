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
    @main_context_id : String?
    @utility_context_id : String?

    # :nodoc:
    def initialize(@id : String, @parent : Frame?, @lock : Sync::Mutex)
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

    # :nodoc:
    #
    # The execution context of the page's own scripts in this frame, used by
    # `Page#evaluate`. `nil` between documents.
    def main_context_id : String?
      @lock.synchronize { @main_context_id }
    end

    # :nodoc:
    #
    # The execution context of the isolated world named
    # `Page::UTILITY_WORLD` in this frame, kept apart from the page's own
    # scripts. Not used yet.
    def utility_context_id : String?
      @lock.synchronize { @utility_context_id }
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

    protected def main_context_id=(@main_context_id : String?) : String?
    end

    protected def utility_context_id=(@utility_context_id : String?) : String?
    end

    # Forgets *context_id* in whichever world holds it.
    protected def clear_context(context_id : String) : Nil
      @main_context_id = nil if @main_context_id == context_id
      @utility_context_id = nil if @utility_context_id == context_id
    end

    protected def clear_contexts : Nil
      @main_context_id = nil
      @utility_context_id = nil
    end
  end
end
