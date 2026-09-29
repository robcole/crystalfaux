# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Portions of this file are translated to Crystal from Camoufox
# (https://github.com/daijro/camoufox, commit eb5dc3bc):
# - `pythonlib/camoufox/fingerprints.py`
#
# Copyright the Camoufox authors. Like all Camoufox-derived files in
# crystalfaux, this file is under the MPL-2.0. See `NOTICE`.

module Crystalfaux::Fingerprint
  # Makes the screen and window keys of a config describe a possible
  # desktop. A page can read all of them, so an impossible combination, such
  # as a window wider than its screen, marks the browser as spoofed.
  #
  # Ported from Camoufox `pythonlib/camoufox/fingerprints.py`:
  # `fix_screen_no_taskbar`, `clamp_window_dimensions` and
  # `clamp_window_position`, applied in that order as `launch_options()`
  # does. Keys that are absent stay absent.
  module Geometry
    AXES = {"Width", "Height"}

    # Corrects the geometry of *config* in place for a desktop of *os*.
    #
    # ```
    # config = {"screen.width" => JSON::Any.new(1920_i64), "window.outerWidth" => JSON::Any.new(2000_i64)}
    # Geometry.fix(config, :windows)
    # config["window.outerWidth"] # => 1920
    # ```
    def self.fix(config : Hash(String, JSON::Any), os : OS) : Nil
      reserve_taskbar(config, os)
      AXES.each { |axis| nest_window(config, axis) }
      AXES.each { |axis| place_window(config, axis) }
    end

    # When the available area is the whole screen, takes the OS taskbar off
    # its height, and shrinks a taller window with it. A desktop always
    # shows some chrome; equal values are a known headless tell.
    private def self.reserve_taskbar(config : Hash(String, JSON::Any), os : OS) : Nil
      width, height = int(config, "screen.width"), int(config, "screen.height")
      return unless width && height
      return unless int(config, "screen.availWidth") == width && int(config, "screen.availHeight") == height
      avail = height - os.taskbar_height
      config["screen.availHeight"] = JSON::Any.new(avail)
      outer = int(config, "window.outerHeight")
      return unless outer && outer > avail
      inner = int(config, "window.innerHeight")
      config["window.outerHeight"] = JSON::Any.new(avail)
      config["window.innerHeight"] = JSON::Any.new(avail - (outer - inner)) if inner
    end

    # Keeps inner <= outer <= avail <= screen on *axis*, keeping the size of
    # the browser chrome (outer minus inner) when the window shrinks.
    private def self.nest_window(config : Hash(String, JSON::Any), axis : String) : Nil
      screen = int(config, "screen.#{axis.downcase}")
      avail = int(config, "screen.avail#{axis}")
      if screen && avail && avail > screen
        avail = screen
        config["screen.avail#{axis}"] = JSON::Any.new(avail)
      end
      cap = avail || screen
      shrink_window(config, axis, cap) if cap

      outer = int(config, "window.outer#{axis}")
      inner = int(config, "window.inner#{axis}")
      config["window.inner#{axis}"] = JSON::Any.new(outer) if outer && inner && inner > outer
    end

    # Shrinks the window to *cap* on *axis* when it is larger.
    private def self.shrink_window(config : Hash(String, JSON::Any), axis : String, cap : Int64) : Nil
      outer = int(config, "window.outer#{axis}")
      return unless outer && outer > cap
      config["window.outer#{axis}"] = JSON::Any.new(cap)
      inner = int(config, "window.inner#{axis}")
      return unless inner
      chrome = {outer - inner, 0_i64}.max
      config["window.inner#{axis}"] = JSON::Any.new({cap - chrome, 1_i64}.max)
    end

    # Keeps the window box inside the screen: 0 <= position <= screen - outer.
    private def self.place_window(config : Hash(String, JSON::Any), axis : String) : Nil
      key = axis == "Width" ? "window.screenX" : "window.screenY"
      screen = int(config, "screen.#{axis.downcase}")
      outer = int(config, "window.outer#{axis}")
      position = int(config, key)
      return unless position && screen && outer
      config[key] = JSON::Any.new(position.clamp(..screen - outer).clamp(0_i64..))
    end

    # The value of *key* as an integer, or `nil` when it is absent or not a
    # number.
    private def self.int(config : Hash(String, JSON::Any), key : String) : Int64?
      case raw = config[key]?.try(&.raw)
      when Int64   then raw
      when Float64 then raw.to_i64
      end
    end
  end
end
