# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Portions of this file are translated to Crystal from Camoufox
# (https://github.com/daijro/camoufox, commit eb5dc3bc):
# - `pythonlib/camoufox/fingerprints.py`
# - `pythonlib/camoufox/utils.py`
#
# Copyright the Camoufox authors. Like all Camoufox-derived files in
# crystalfaux, this file is under the MPL-2.0. See `NOTICE`.

module Crystalfaux::Fingerprint
  # A validated Camoufox fingerprint config: the object that the browser
  # reads from `CAMOU_CONFIG_1..N` at startup.
  #
  # Every key must be one that the vendored `properties.json` lists, and
  # its value must have that key's type; otherwise the constructors raise
  # `ConfigError`. Camoufox's Python launcher skips unknown keys with a
  # message instead. crystalfaux raises, so that a misspelt key cannot
  # silently leave the real value exposed.
  #
  # ```
  # config = Crystalfaux::Fingerprint::Config.from_json(File.read("camoufox-config.json"))
  # config = Crystalfaux::Fingerprint::Config.new({"screen.width" => 1512, "screen.height" => 982})
  # browser = Crystalfaux::Browser.launch(config: config)
  # ```
  #
  # Validation checks keys and types only. It does not correct the geometry
  # of a config from Camoufox's generators, which already did; `.for` and
  # `Geometry.fix` do that.
  #
  # A config does not change after it is built: it keeps deep copies of the
  # values it is given, and `#[]`, `#[]?` and `#to_h` return deep copies, so
  # a caller cannot change a validated value. `#merge` returns a new config.
  struct Config
    # The fields of every `voices` entry: Camoufox `MaskConfig::MVoices()`
    # skips an entry without one of them (`VOICE_FIELDS` in
    # `pythonlib/camoufox/utils.py`).
    VOICE_FIELDS = {"lang", "name", "voiceUri", "isDefault", "isLocalService"}

    @values : Hash(String, JSON::Any)

    # Builds a config from *values*. Raises `ConfigError` when a key is
    # unknown or a value has the wrong type.
    def initialize(values : Hash(String, JSON::Any))
      @values = values.to_h { |key, value| {key, Config.validate(key, value.clone)} }
    end

    # Builds a config from a hash of values that serialize to JSON, such as
    # `{"screen.width" => 1512, "navigator.platform" => "MacIntel"}`.
    def self.new(values : Hash(String, T)) : self forall T
      from_json(values.to_json)
    end

    # Builds a config from a JSON object, such as the `CAMOU_CONFIG` object
    # that Camoufox's `launch_options()` (Python) or `launchOptions()`
    # (TypeScript) produced. Raises `ConfigError` when *json* is not a JSON
    # object, or as `.new`.
    def self.from_json(json : String | IO) : self
      values = JSON.parse(json).as_h?
      raise ConfigError.new("The config must be a JSON object") unless values
      new(values)
    rescue ex : JSON::ParseException
      raise ConfigError.new("Invalid config JSON: #{ex.message}")
    end

    # Builds a deterministic config for a desktop of *os* with *screen* and
    # *user_agent*. It sets the keys that must agree with one another:
    #
    # - `navigator.userAgent`, `headers.User-Agent`, and the
    #   `navigator.platform`, `navigator.oscpu` and `navigator.appVersion`
    #   that Firefox reports with that user agent;
    # - `screen.*` with the OS taskbar taken off the available height;
    # - `window.outer*` and `window.screenX/Y`: the window fills the
    #   available area, or has the size of *window*, centred;
    # - `fonts`: every font of *os* in the vendored `fonts.json`.
    #
    # Raises `ConfigError` when *user_agent* names another OS, or when
    # *screen* or *window* has no area. Add other keys with `#merge`.
    #
    # ```
    # config = Crystalfaux::Fingerprint::Config.for(
    #   os: :windows,
    #   screen: Crystalfaux::Fingerprint::Screen.new(1920, 1080),
    #   user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:152.0) Gecko/20100101 Firefox/152.0",
    # )
    # config["screen.availHeight"] # => 1040
    # config["navigator.platform"] # => "Win32"
    # ```
    def self.for(*, os : OS, screen : Screen, user_agent : String, window : Screen? = nil) : self
      check_area("screen", screen)
      window.try { |size| check_area("window", size) }
      named = OS.from_user_agent(user_agent)
      raise ConfigError.new("The user agent is for #{named}, not #{os}") unless named == os

      values = navigator_values(os, user_agent)
      values.merge!(geometry_values(os, screen, window))
      values["fonts"] = JSON::Any.new(os.fonts.map { |font| JSON::Any.new(font) })
      Geometry.fix(values, os)
      new(values)
    end

    # The value of *key*. Raises `KeyError` when the config has no *key*.
    def [](key : String) : JSON::Any
      @values[key].clone
    end

    # The value of *key*, or `nil` when the config has no *key*.
    def []?(key : String) : JSON::Any?
      @values[key]?.try(&.clone)
    end

    # Returns a new config with the keys of *values* added or replaced.
    # Raises as `.new`.
    def merge(values : Hash(String, JSON::Any)) : Config
      Config.new(@values.merge(values))
    end

    # A deep copy of the values.
    def to_h : Hash(String, JSON::Any)
      @values.clone
    end

    def to_json(json : JSON::Builder) : Nil
      @values.to_json(json)
    end

    def ==(other : Config) : Bool
      @values == other.@values
    end

    # :nodoc:
    #
    # Raises `ConfigError` unless *key* is a known property and *value* has
    # its type. Returns *value* normalized for that type.
    def self.validate(key : String, value : JSON::Any) : JSON::Any
      type = Properties::TYPES[key]?
      raise ConfigError.new("Unknown config key #{key.inspect}") unless type
      unless type.matches?(value)
        raise ConfigError.new(
          "Invalid type for config key #{key.inspect}: expected #{type.json_name}, got #{json_type(value)}")
      end
      validate_voices(value.as_a) if key == "voices"
      type.normalize(value)
    end

    private def self.validate_voices(voices : Array(JSON::Any)) : Nil
      voices.each_with_index do |voice, index|
        fields = voice.as_h?
        unless fields
          raise ConfigError.new(
            "Invalid voices[#{index}]: expected an object with #{VOICE_FIELDS.join(", ")}, got #{json_type(voice)}")
        end
        missing = VOICE_FIELDS.reject { |field| fields.has_key?(field) }
        raise ConfigError.new("Invalid voices[#{index}]: missing #{missing.join(", ")}") unless missing.empty?
      end
    end

    private def self.json_type(value : JSON::Any) : String
      case value.raw
      in Nil                     then "null"
      in Bool                    then "boolean"
      in Int64, Float64          then "number"
      in String                  then "string"
      in Array(JSON::Any)        then "array"
      in Hash(String, JSON::Any) then "object"
      end
    end

    private def self.check_area(name : String, size : Screen) : Nil
      return if size.width > 0 && size.height > 0
      raise ConfigError.new("The #{name} size must be positive, got #{size.width}x#{size.height}")
    end

    private def self.navigator_values(os : OS, user_agent : String) : Hash(String, JSON::Any)
      values = {
        "navigator.userAgent" => JSON::Any.new(user_agent),
        "headers.User-Agent"  => JSON::Any.new(user_agent),
        "navigator.platform"  => JSON::Any.new(os.platform(user_agent)),
        "navigator.oscpu"     => JSON::Any.new(os.oscpu(user_agent)),
      }
      app_version(user_agent).try { |version| values["navigator.appVersion"] = JSON::Any.new(version) }
      values
    end

    # The `navigator.appVersion` that Firefox reports with *user_agent*:
    # its OS tokens without the architecture and `rv:`, with Windows
    # reduced to its family name (`_app_version_from_user_agent` in Camoufox
    # `pythonlib/camoufox/fingerprints.py`).
    private def self.app_version(user_agent : String) : String?
      kept = OS.platform_tokens(user_agent).compact_map do |token|
        next if token.starts_with?("rv:") || token.in?("Win64", "x64", "Mobile", "Tablet")
        next if token.starts_with?("Linux ") || token.starts_with?("Intel Mac OS X")
        token.starts_with?("Windows") ? "Windows" : token
      end
      "5.0 (#{kept.join("; ")})" unless kept.empty?
    end

    # The screen, the available area and the window box. The window is
    # centred as `handle_window_size` in Camoufox
    # `pythonlib/camoufox/fingerprints.py`; `Geometry.fix` then fits it.
    private def self.geometry_values(os : OS, screen : Screen, window : Screen?) : Hash(String, JSON::Any)
      avail_height = {screen.height - os.taskbar_height, 1}.max
      outer = window || Screen.new(screen.width, avail_height)
      x = window ? (screen.width - outer.width) // 2 : 0
      y = window ? (screen.height - outer.height) // 2 : 0
      {
        "screen.width"       => screen.width,
        "screen.height"      => screen.height,
        "screen.availWidth"  => screen.width,
        "screen.availHeight" => avail_height,
        "window.outerWidth"  => outer.width,
        "window.outerHeight" => outer.height,
        "window.screenX"     => x,
        "window.screenY"     => y,
      }.transform_values { |value| JSON::Any.new(value.to_i64) }
    end
  end
end
