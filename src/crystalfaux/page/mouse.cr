# Portions of this file are translated to Crystal from Playwright
# (https://github.com/microsoft/playwright):
# - `packages/playwright-core/src/server/input.ts`
# - `packages/playwright-core/src/server/firefox/ffInput.ts`
#
# Copyright 2017 Google Inc. Modifications copyright (c) Microsoft Corporation.
# Licensed under the Apache License, Version 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). See `NOTICE`.

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
      # A mouse button.
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

      # Resolves at the next animation frame; Juggler awaits the promise.
      ANIMATION_FRAME_SCRIPT = "new Promise(requestAnimationFrame)"

      # How long a release that cleans up after a press may wait for its
      # reply. It does not depend on the deadline of the action, which can
      # have passed. A page listener that is busy during the press also
      # delays the release, so this allows for a slow listener.
      RELEASE_TIMEOUT = 2.seconds

      @lock = Sync::Mutex.new
      @x = 0.0
      @y = 0.0
      @buttons = Set(Button).new

      # :nodoc:
      def initialize(@page : Page, @keyboard : Keyboard)
      end

      # Moves the mouse to (*x*, *y*) in *steps* even moves from where it is.
      def move(x : Float64, y : Float64, steps : Int32 = 1, *, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
        move_to(x, y, steps, Time.instant + timeout)
      end

      # Presses *button* where the mouse is.
      #
      # When the press was sent but fails, for example because its reply
      # does not come in time, the mouse releases *button* again; see
      # `#click`.
      def down(button : Button = :left, click_count : Int32 = 1, *, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
        press(button, click_count, Time.instant + timeout)
      end

      # Releases *button* where the mouse is.
      def up(button : Button = :left, click_count : Int32 = 1, *, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
        release(button, click_count, Time.instant + timeout)
      end

      # Moves to (*x*, *y*) and clicks *button* *click_count* times; 2 is a
      # double click.
      #
      # *timeout* covers all the events. Raises `TimeoutError` when it
      # passes. After that the mouse starts no other event, but a pressed
      # button is always released, so no button stays down. The release
      # of a sent press can take up to `RELEASE_TIMEOUT` after *timeout*.
      #
      # - When the deadline passes before a press, the press is not sent,
      #   and the message says so.
      # - When a press was sent, a failure of the press or the deadline
      #   passing before the release makes the mouse send the release with
      #   its own allowance, `RELEASE_TIMEOUT`. The `TimeoutError` then says
      #   that the click is partial, and whether the release failed. When
      #   the reply of a press or release did not come, the event may or may
      #   not have reached the page; the message says that delivery is
      #   uncertain.
      #
      # The mouse does not press again or retry. When the page or the
      # connection is gone, no release can be sent, and the call raises
      # that failure, such as `PageClosed`.
      def click(x : Float64, y : Float64, button : Button = :left, click_count : Int32 = 1, *,
                timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
        deadline = Time.instant + timeout
        move_to(x, y, 1, deadline)
        (1..click_count).each do |count|
          press(button, count, deadline)
          release_pressed(button, count, deadline)
        end
      end

      # Turns the wheel where the mouse is. Positive *delta_y* scrolls down.
      #
      # Waits for an animation frame first: wheel events reach the
      # compositor, which must have the current layout to hit-test them
      # (Playwright `server/firefox/ffInput.ts`, `RawMouseImpl.wheel`).
      # Playwright waits in its utility world; this waits in the isolated
      # world, the default world of `Page#evaluate`.
      def wheel(delta_x : Float64, delta_y : Float64) : Nil
        @page.evaluate(ANIMATION_FRAME_SCRIPT)
        x, y = @lock.synchronize { {@x, @y} }
        @page.dispatch(Protocol::Page::DispatchWheelEvent.new(x.floor, y.floor, delta_x: delta_x, delta_y: delta_y,
          modifiers: @keyboard.modifiers.value))
      end

      private def move_to(x : Float64, y : Float64, steps : Int32, deadline : Time::Instant) : Nil
        from_x, from_y = @lock.synchronize { {@x, @y} }
        (1..steps).each do |step|
          fraction = step / steps
          to_x = from_x + (x - from_x) * fraction
          to_y = from_y + (y - from_y) * fraction
          @lock.synchronize do
            @x = to_x
            @y = to_y
          end
          send_button_event(:mousemove, Button::Left, nil, held_buttons, deadline)
        end
      end

      # Sends the press, and holds *button* once the browser acknowledged
      # it. When the press was sent but fails, releases *button*.
      private def press(button : Button, click_count : Int32, deadline : Time::Instant) : Nil
        check_deadline(:mousedown, deadline)
        begin
          send_button_event(:mousedown, button, click_count, held_buttons | button.mask, deadline)
        rescue ex
          raise abandon_press(ex, button, click_count,
            "The mousedown event was sent, but its reply did not come in time, so its delivery is uncertain")
        end
        @lock.synchronize { @buttons << button }
      end

      # Releases *button* after a press of `#click` that the browser
      # acknowledged. The release is part of the action that the press
      # started, so it is sent also when the deadline has passed, with
      # `RELEASE_TIMEOUT`; the click then raises `TimeoutError`.
      private def release_pressed(button : Button, click_count : Int32, deadline : Time::Instant) : Nil
        unless (deadline - Time.instant).positive?
          raise abandon_press(TimeoutError.new("The deadline passed"), button, click_count,
            "The deadline passed after the mousedown event and before the mouseup event")
        end
        release_deadline = {deadline, Time.instant + RELEASE_TIMEOUT}.max
        send_release(button, click_count, release_deadline)
      end

      private def release(button : Button, click_count : Int32, deadline : Time::Instant) : Nil
        check_deadline(:mouseup, deadline)
        send_release(button, click_count, deadline)
      end

      # Stops holding *button*, then sends its release. A release that is
      # not acknowledged is not sent again.
      private def send_release(button : Button, click_count : Int32, deadline : Time::Instant) : Nil
        @lock.synchronize { @buttons.delete(button) }
        send_button_event(:mouseup, button, click_count, held_buttons, deadline)
      rescue ex : TimeoutError
        raise TimeoutError.new("The mouseup event was sent, but its reply did not come in time, " \
                               "so its delivery is uncertain; the action is partial", cause: ex)
      end

      # Cleans up after *failure* of an action whose press was sent: stops
      # holding *button* and releases it with `RELEASE_TIMEOUT`. Returns
      # the error to raise: a `TimeoutError` that says what happened
      # (*stage*) and how the release went, or *failure* itself when it is
      # not a timeout, such as the failure of a closed page.
      private def abandon_press(failure : Exception, button : Button, click_count : Int32, stage : String) : Exception
        @lock.synchronize { @buttons.delete(button) }
        cleanup = cleanup_release(button, click_count)
        return failure unless failure.is_a?(TimeoutError)
        TimeoutError.new("#{stage}; the action is partial. #{cleanup}", cause: failure)
      end

      # Sends the release for `#abandon_press` and describes the outcome.
      # A closed page or connection raises at once, so this does not wait
      # for a page that is gone.
      private def cleanup_release(button : Button, click_count : Int32) : String
        send_button_event(:mouseup, button, click_count, held_buttons, Time.instant + RELEASE_TIMEOUT)
        "The mouseup event was sent to release the button."
      rescue ex
        "Releasing the button failed: #{ex.message}"
      end

      # The `buttons` mask of the held buttons.
      private def held_buttons : Int32
        @lock.synchronize { @buttons.sum(&.mask) }
      end

      private def check_deadline(type : Protocol::Page::MouseEventType, deadline : Time::Instant) : Nil
        return if (deadline - Time.instant).positive?
        raise TimeoutError.new("The #{type.wire_name} event was not sent: the deadline passed")
      end

      # A move always reports the left button, as Playwright's `ffInput.ts`
      # does. Juggler takes whole pixels (Playwright floors them too).
      # *buttons* is the `buttons` mask the event reports.
      private def send_button_event(type : Protocol::Page::MouseEventType, button : Button, click_count : Int32?,
                                    buttons : Int32, deadline : Time::Instant) : Nil
        x, y = @lock.synchronize { {@x, @y} }
        @page.dispatch(Protocol::Page::DispatchMouseEvent.new(type, x.floor, y.floor, button: button.number,
          buttons: buttons, modifiers: @keyboard.modifiers.value, click_count: click_count), deadline)
      end
    end
  end
end
