module Crystalfaux::Protocol
  # The `Page` domain: per-page navigation, frames, input, screenshots and
  # lifecycle events. The structs sit in one file because each is a small
  # value type of the same schema section.
  module Page
    # The `LifecycleEvent` enum of the Juggler schema.
    Protocol.wire_enum(LifecycleEvent, load: "load", dom_content_loaded: "DOMContentLoaded")
    # The `MouseEventType` enum of the Juggler schema.
    Protocol.wire_enum(MouseEventType, mousedown: "mousedown", mousemove: "mousemove", mouseup: "mouseup")
    # The image format of a screenshot: `png`, `jpeg` or `webp`.
    Protocol.wire_enum(ImageType, png: "image/png", jpeg: "image/jpeg", webp: "image/webp")

    # The `Size` type of the Juggler schema.
    struct Size
      include Message

      field width : Float64
      field height : Float64

      def initialize(@width : Float64, @height : Float64)
      end
    end

    # A rectangle in CSS pixels, relative to the top of the page.
    struct Clip
      include Message

      field x : Float64
      field y : Float64
      field width : Float64
      field height : Float64

      def initialize(@x : Float64, @y : Float64, @width : Float64, @height : Float64)
      end
    end

    # The `Page.navigate` request.
    struct Navigate
      include Message

      # The result of `Page.navigate`.
      struct Result
        include Message

        # `nil` for a navigation that stays in the same document.
        field navigation_id : String?, emit_null: true
      end

      include Request(Result)
      METHOD = "Page.navigate"

      field frame_id : String
      field url : String
      field referer : String?

      def initialize(@frame_id : String, @url : String, @referer : String? = nil)
      end
    end

    # The `Page.close` request.
    struct Close
      include Message
      include Request(Empty)
      METHOD = "Page.close"

      field run_before_unload : Bool?

      def initialize(@run_before_unload : Bool? = nil)
      end
    end

    # Sets the viewport. A `nil` *viewport_size* resets it to the window.
    struct SetViewportSize
      include Message
      include Request(Empty)
      METHOD = "Page.setViewportSize"

      field viewport_size : Size?, emit_null: true
      field device_scale_factor : Float64?
      field screen_size : Size?
      field is_mobile : Bool?

      def initialize(@viewport_size : Size?, *, @device_scale_factor : Float64? = nil,
                     @screen_size : Size? = nil, @is_mobile : Bool? = nil)
      end
    end

    # The `Page.screenshot` request.
    struct Screenshot
      include Message

      # The result of `Page.screenshot`.
      struct Result
        include Message

        # The image, base64-encoded.
        field data : String
      end

      include Request(Result)
      METHOD = "Page.screenshot"

      field mime_type : ImageType
      field clip : Clip
      # JPEG quality, 0 to 100.
      field quality : Int32?
      field omit_device_scale_factor : Bool?

      def initialize(@mime_type : ImageType, @clip : Clip, *, @quality : Int32? = nil,
                     @omit_device_scale_factor : Bool? = nil)
      end
    end

    # Sends one key event. *type* is `"keydown"` or `"keyup"`; the schema
    # gives it as a plain string.
    struct DispatchKeyEvent
      include Message
      include Request(Empty)
      METHOD = "Page.dispatchKeyEvent"

      field type : String
      field key : String
      field key_code : Int32
      field location : Int32
      field code : String
      field repeat : Bool
      field text : String?

      def initialize(@type : String, @key : String, @key_code : Int32, @code : String, *,
                     @location : Int32 = 0, @repeat : Bool = false, @text : String? = nil)
      end
    end

    # Sends one mouse event. *button* is 0 (left), 1 (middle) or 2 (right);
    # *buttons* and *modifiers* are bit masks.
    struct DispatchMouseEvent
      include Message
      include Request(Empty)
      METHOD = "Page.dispatchMouseEvent"

      field type : MouseEventType
      field button : Int32
      field x : Float64
      field y : Float64
      field modifiers : Int32
      field click_count : Int32?
      field buttons : Int32

      def initialize(@type : MouseEventType, @x : Float64, @y : Float64, *, @button : Int32 = 0,
                     @buttons : Int32 = 0, @modifiers : Int32 = 0, @click_count : Int32? = nil)
      end
    end

    # The `Page.dispatchWheelEvent` request.
    struct DispatchWheelEvent
      include Message
      include Request(Empty)
      METHOD = "Page.dispatchWheelEvent"

      field x : Float64
      field y : Float64
      field delta_x : Float64
      field delta_y : Float64
      field delta_z : Float64
      field modifiers : Int32

      def initialize(@x : Float64, @y : Float64, *, @delta_x : Float64 = 0.0, @delta_y : Float64 = 0.0,
                     @delta_z : Float64 = 0.0, @modifiers : Int32 = 0)
      end
    end

    # Inserts *text* at the focused element, as an input method would.
    struct InsertText
      include Message
      include Request(Empty)
      METHOD = "Page.insertText"

      field text : String

      def initialize(@text : String)
      end
    end

    # The `DOMPoint` type of the Juggler schema.
    struct Point
      include Message

      field x : Float64
      field y : Float64
    end

    # The `DOMQuad` type of the Juggler schema: four corners, clockwise from
    # the top left for an element without a transform.
    struct Quad
      include Message

      field p1 : Point
      field p2 : Point
      field p3 : Point
      field p4 : Point

      # The corners in order.
      def points : {Point, Point, Point, Point}
        {p1, p2, p3, p4}
      end
    end

    # The `Rect` type of the Juggler schema.
    struct Rect
      include Message

      field x : Float64
      field y : Float64
      field width : Float64
      field height : Float64

      def initialize(@x : Float64, @y : Float64, @width : Float64, @height : Float64)
      end
    end

    # Scrolls the element *object_id* of frame *frame_id* into view unless
    # it is already visible.
    struct ScrollIntoViewIfNeeded
      include Message
      include Request(Empty)
      METHOD = "Page.scrollIntoViewIfNeeded"

      field frame_id : String
      field object_id : String
      field rect : Rect?

      def initialize(@frame_id : String, @object_id : String, @rect : Rect? = nil)
      end
    end

    # The border-box quads of the element *object_id* of frame *frame_id*,
    # in CSS pixels relative to the main frame's viewport. An element that
    # is not rendered has none.
    struct GetContentQuads
      include Message

      # The reply of `GetContentQuads`.
      struct Result
        include Message

        field quads : Array(Quad)
      end

      include Request(Result)
      METHOD = "Page.getContentQuads"

      field frame_id : String
      field object_id : String

      def initialize(@frame_id : String, @object_id : String)
      end
    end

    # The `Page.ready` event.
    struct Ready
      include Message
      METHOD = "Page.ready"
    end

    # The `Page.crashed` event.
    struct Crashed
      include Message
      METHOD = "Page.crashed"
    end

    # The `Page.eventFired` event.
    struct EventFired
      include Message
      METHOD = "Page.eventFired"

      field frame_id : String
      field name : LifecycleEvent
    end

    # A frame exists. The main frame has no *parent_frame_id*.
    struct FrameAttached
      include Message
      METHOD = "Page.frameAttached"

      field frame_id : String
      field parent_frame_id : String?
    end

    # The `Page.frameDetached` event.
    struct FrameDetached
      include Message
      METHOD = "Page.frameDetached"

      field frame_id : String
    end

    # The `Page.navigationStarted` event.
    struct NavigationStarted
      include Message
      METHOD = "Page.navigationStarted"

      field frame_id : String
      field navigation_id : String
    end

    # The `Page.navigationCommitted` event.
    struct NavigationCommitted
      include Message
      METHOD = "Page.navigationCommitted"

      field frame_id : String
      # `nil` only in the events sent when the page is enabled.
      field navigation_id : String?
      field url : String
      # The frame's id or name.
      field name : String
    end

    # The `Page.navigationAborted` event.
    struct NavigationAborted
      include Message
      METHOD = "Page.navigationAborted"

      field frame_id : String
      field navigation_id : String
      field error_text : String
    end

    # The `Page.sameDocumentNavigation` event.
    struct SameDocumentNavigation
      include Message
      METHOD = "Page.sameDocumentNavigation"

      field frame_id : String
      field url : String
    end
  end
end
