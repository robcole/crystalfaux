# Portions of this file are translated to Crystal from Playwright
# (https://github.com/microsoft/playwright):
# - `packages/playwright-core/src/server/usKeyboardLayout.ts`
# - `packages/playwright-core/src/server/input.ts`
#
# Copyright 2017 Google Inc. Modifications copyright (c) Microsoft Corporation.
# Licensed under the Apache License, Version 2.0
# (https://www.apache.org/licenses/LICENSE-2.0). See `NOTICE`.

module Crystalfaux
  class Page
    # :nodoc:
    #
    # A US keyboard layout for `Keyboard`: printable ASCII and the common
    # named keys. Ported in part from Playwright's
    # `server/usKeyboardLayout.ts` and the lookup that `server/input.ts`
    # builds from it.
    #
    # A key is found by its `code` (`"KeyA"`), by the character it types
    # (`"a"`, `"A"`), or by its name (`"Enter"`, `"Shift"`).
    module KeyboardLayout
      # What one key sends. *key_code* is the Windows virtual key code that
      # Juggler expects; *location* is 1 for a left modifier key.
      record Key, key : String, code : String, key_code : Int32, text : String = "", location : Int32 = 0

      # A key and, when Shift changes it, what it sends with Shift held.
      record Entry, key : Key, shifted : Key? = nil

      # Characters on the digit and punctuation keys: code, key code,
      # character, shifted character.
      CHARACTER_KEYS = [
        {"Digit1", 49, "1", "!"}, {"Digit2", 50, "2", "@"}, {"Digit3", 51, "3", "#"},
        {"Digit4", 52, "4", "$"}, {"Digit5", 53, "5", "%"}, {"Digit6", 54, "6", "^"},
        {"Digit7", 55, "7", "&"}, {"Digit8", 56, "8", "*"}, {"Digit9", 57, "9", "("},
        {"Digit0", 48, "0", ")"}, {"Minus", 189, "-", "_"}, {"Equal", 187, "=", "+"},
        {"BracketLeft", 219, "[", "{"}, {"BracketRight", 221, "]", "}"},
        {"Backslash", 220, "\\", "|"}, {"Semicolon", 186, ";", ":"}, {"Quote", 222, "'", "\""},
        {"Backquote", 192, "`", "~"}, {"Comma", 188, ",", "<"}, {"Period", 190, ".", ">"},
        {"Slash", 191, "/", "?"},
      ]

      # Keys whose code is also their name: code, key code, text.
      NAMED_KEYS = [
        {"Enter", 13, "\r"}, {"Tab", 9, ""}, {"Backspace", 8, ""}, {"Escape", 27, ""},
        {"Delete", 46, ""}, {"Insert", 45, ""}, {"Home", 36, ""}, {"End", 35, ""},
        {"PageUp", 33, ""}, {"PageDown", 34, ""}, {"ArrowLeft", 37, ""}, {"ArrowUp", 38, ""},
        {"ArrowRight", 39, ""}, {"ArrowDown", 40, ""},
      ]

      # The left modifier keys: code, key code, name.
      MODIFIER_KEYS = [
        {"ShiftLeft", 16, "Shift"}, {"ControlLeft", 17, "Control"},
        {"AltLeft", 18, "Alt"}, {"MetaLeft", 91, "Meta"},
      ]

      ENTRIES = build

      # The entry for *name*, or `nil` when the layout has no such key.
      def self.[]?(name : String) : Entry?
        ENTRIES[name]?
      end

      private def self.build : Hash(String, Entry)
        entries = {} of String => Entry
        ('a'..'z').each do |letter|
          add_character(entries, "Key#{letter.upcase}", letter.upcase.ord, letter.to_s, letter.upcase.to_s)
        end
        CHARACTER_KEYS.each { |code, key_code, key, shifted| add_character(entries, code, key_code, key, shifted) }
        add_character(entries, "Space", 32, " ", nil)
        NAMED_KEYS.each { |code, key_code, text| entries[code] = Entry.new(Key.new(code, code, key_code, text)) }
        # Enter also types a line break (Playwright's layout aliases).
        entries["\n"] = entries["\r"] = entries["Enter"]
        MODIFIER_KEYS.each do |code, key_code, name|
          entries[code] = entries[name] = Entry.new(Key.new(name, code, key_code, location: 1))
        end
        entries
      end

      # Adds a key that types *key*, and types *shifted* with Shift held. The
      # key is found by its code and by both characters.
      private def self.add_character(entries : Hash(String, Entry), code : String, key_code : Int32,
                                     key : String, shifted : String?) : Nil
        entry = Entry.new(Key.new(key, code, key_code, key), shifted.try { |char| Key.new(char, code, key_code, char) })
        entries[code] = entries[key] = entry
        entry.shifted.try { |shifted_key| entries[shifted_key.key] = Entry.new(shifted_key) }
      end
    end
  end
end
