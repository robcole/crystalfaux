module Crystalfaux
  class Page
    # The keyboard of a `Page`. It sends key events to the focused element
    # and keeps track of the keys that are down.
    #
    # ```
    # page.keyboard.type("hello")
    # page.keyboard.press("Enter")
    # page.keyboard.press("Shift+ArrowLeft")
    # page.keyboard.insert_text("日本")
    # ```
    #
    # Keys are named as in Playwright: a character (`"a"`, `"A"`, `"+"`), a
    # key name (`"Enter"`, `"Tab"`, `"Backspace"`, `"Escape"`, `"ArrowUp"`,
    # `"Shift"`, `"Control"`, `"Alt"`, `"Meta"`), or a code (`"KeyA"`). Only
    # a US layout is known. Unknown keys raise `ArgumentError`.
    #
    # Semantics follow Playwright's `server/input.ts` and
    # `server/firefox/ffInput.ts`: with Shift down a key sends its shifted
    # character, and with any other modifier down it sends no text.
    #
    # Each event is one request; the calls raise what `Page#evaluate` raises
    # when the page goes away. Use one keyboard from one fiber at a time:
    # the keys that are down are shared state.
    class Keyboard
      # The modifier keys, as the bit set of Juggler's `modifiers` field
      # (Playwright `server/firefox/ffInput.ts`, `toModifiersMask`; the
      # values of Firefox's `nsIDOMWindowUtils.MODIFIER_*`).
      @[Flags]
      enum Modifier
        Alt     = 1
        Control = 2
        Shift   = 4
        Meta    = 8
      end

      @lock = Sync::Mutex.new
      @modifiers = Modifier::None
      @pressed_codes = Set(String).new

      # :nodoc:
      def initialize(@page : Page)
      end

      # The modifier keys that are down.
      def modifiers : Modifier
        @lock.synchronize { @modifiers }
      end

      # Sends a key down for *key*. A key that is already down is sent as a
      # repeat.
      def down(key : String) : Nil
        description, repeat = @lock.synchronize do
          pressed = describe(key)
          @modifiers |= modifier_of(pressed)
          {pressed, !@pressed_codes.add?(pressed.code)}
        end
        # Firefox makes the text of Enter itself (Playwright `ffInput.ts`).
        text = description.text
        text = nil if text.empty? || text == "\r"
        @page.dispatch(Protocol::Page::DispatchKeyEvent.new("keydown", description.key, description.key_code,
          description.code, location: description.location, repeat: repeat, text: text))
      end

      # Sends a key up for *key*.
      def up(key : String) : Nil
        description = @lock.synchronize do
          released = describe(key)
          @modifiers &= ~modifier_of(released)
          @pressed_codes.delete(released.code)
          released
        end
        @page.dispatch(Protocol::Page::DispatchKeyEvent.new("keyup", description.key, description.key_code,
          description.code, location: description.location))
      end

      # Presses and releases *key*. Joins modifiers with `+`, as in
      # `"Control+Shift+a"`: they go down in order and up in reverse.
      def press(key : String) : Nil
        keys = split(key)
        # Checks every key first, so an unknown key sends nothing.
        keys.each { |name| entry_for(name) }
        keys.each { |name| down(name) }
        keys.reverse_each { |name| up(name) }
      end

      # Presses the key of each character of *text*. A character with no
      # key in the layout is inserted with `#insert_text`.
      def type(text : String) : Nil
        text.each_char do |char|
          if KeyboardLayout[char.to_s]?
            press(char.to_s)
          else
            insert_text(char.to_s)
          end
        end
      end

      # Inserts *text* at the focused element without key events, as an
      # input method does.
      def insert_text(text : String) : Nil
        @page.dispatch(Protocol::Page::InsertText.new(text))
      end

      # Splits a combination at each `+` that follows a key name, so `"+"`
      # and `"Shift++"` keep the plus key (Playwright `server/input.ts`).
      private def split(combination : String) : Array(String)
        keys = [] of String
        building = String::Builder.new
        combination.each_char do |char|
          if char == '+' && !building.empty?
            keys << building.to_s
            building = String::Builder.new
          else
            building << char
          end
        end
        keys << building.to_s
      end

      # Call with `@lock` held.
      private def describe(key : String) : KeyboardLayout::Key
        entry = entry_for(key)
        shifted = entry.shifted if @modifiers.shift?
        description = shifted || entry.key
        return description if (@modifiers & ~Modifier::Shift).none?
        description.copy_with(text: "")
      end

      private def entry_for(key : String) : KeyboardLayout::Entry
        KeyboardLayout[key]? || raise ArgumentError.new("Unknown key: #{key.inspect}")
      end

      private def modifier_of(description : KeyboardLayout::Key) : Modifier
        Modifier.parse?(description.key) || Modifier::None
      end
    end
  end
end
