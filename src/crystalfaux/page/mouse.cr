module Crystalfaux
  class Page
    # The mouse of a `Page`. Coordinates are CSS pixels from the top-left
    # corner of the viewport.
    #
    # ```
    # page.mouse.click(120, 48)
    # page.mouse.move(0, 0)
    # page.mouse.wheel(0, 400) # scrolls down
    # ```
    #
    # Semantics follow Playwright's `server/input.ts` and
    # `server/firefox/ffInput.ts`: a click is a move, then a down and an up
    # for each click of *click_count*. Events carry the buttons that are
    # down and the modifier keys that the page's `Keyboard` holds.
    #
    # Each event is one request; the calls raise what `Page#evaluate` raises
    # when the page goes away. Use one mouse from one fiber at a time: its
    # position and buttons are shared state.
    class Mouse
      enum Button
        Left
        Middle
        Right

        # Juggler's `button` field (Playwright `ffInput.ts`,
        # `toButtonNumber`).
        def number : Int32
          case self
          in Left   then 0
          in Middle then 1
          in Right  then 2
          end
        end

        # This button's bit in Juggler's `buttons` field (Playwright
        # `ffInput.ts`, `toButtonsMask`).
        def mask : Int32
          case self
          in Left   then 1
          in Right  then 2
          in Middle then 4
          end
        end
      end

      @lock = Sync::Mutex.new
      @x = 0.0
      @y = 0.0
      @buttons = Set(Button).new

      # :nodoc:
      def initialize(@page : Page, @keyboard : Keyboard)
      end

      # Moves the mouse to (*x*, *y*) in *steps* even moves from where it is.
      def move(x : Float64, y : Float64, steps : Int32 = 1) : Nil
        from_x, from_y = @lock.synchronize { {@x, @y} }
        (1..steps).each do |step|
          fraction = step / steps
          to_x = from_x + (x - from_x) * fraction
          to_y = from_y + (y - from_y) * fraction
          @lock.synchronize do
            @x = to_x
            @y = to_y
          end
          send_button_event(:mousemove, Button::Left, click_count: nil)
        end
      end

      # Presses *button* where the mouse is.
      def down(button : Button = :left, click_count : Int32 = 1) : Nil
        @lock.synchronize { @buttons << button }
        send_button_event(:mousedown, button, click_count)
      end

      # Releases *button* where the mouse is.
      def up(button : Button = :left, click_count : Int32 = 1) : Nil
        @lock.synchronize { @buttons.delete(button) }
        send_button_event(:mouseup, button, click_count)
      end

      # Moves to (*x*, *y*) and clicks *button* *click_count* times; 2 is a
      # double click.
      def click(x : Float64, y : Float64, button : Button = :left, click_count : Int32 = 1) : Nil
        move(x, y)
        (1..click_count).each do |count|
          down(button, count)
          up(button, count)
        end
      end

      # Turns the wheel where the mouse is. Positive *delta_y* scrolls down.
      def wheel(delta_x : Float64, delta_y : Float64) : Nil
        x, y = @lock.synchronize { {@x, @y} }
        @page.dispatch(Protocol::Page::DispatchWheelEvent.new(x.floor, y.floor, delta_x: delta_x, delta_y: delta_y,
          modifiers: @keyboard.modifiers.value))
      end

      # A move always reports the left button, as Playwright's `ffInput.ts`
      # does. Juggler takes whole pixels (Playwright floors them too).
      private def send_button_event(type : Protocol::Page::MouseEventType, button : Button, click_count : Int32?) : Nil
        x, y, buttons = @lock.synchronize { {@x, @y, @buttons.sum(&.mask)} }
        @page.dispatch(Protocol::Page::DispatchMouseEvent.new(type, x.floor, y.floor, button: button.number,
          buttons: buttons, modifiers: @keyboard.modifiers.value, click_count: click_count))
      end
    end
  end
end
