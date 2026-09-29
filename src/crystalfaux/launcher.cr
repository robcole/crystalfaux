require "json"

# Builds the command line and environment for Camoufox and runs it.
#
# The functions in this module are pure. `BrowserProcess` uses them to start
# the browser; `Discovery` finds the binary.
#
# ```
# options = Crystalfaux::Launcher::Options.new(headless: true)
# Crystalfaux::Launcher.arguments(options, "/tmp/profile")
# # => ["-no-remote", "-headless", "-profile", "/tmp/profile", "-juggler-pipe", "-silent"]
# Crystalfaux::Launcher.environment(options, base: {"PATH" => "/usr/bin"})
# # => {"PATH" => "/usr/bin", "CAMOU_CONFIG_1" => "{}", "CAMOU_PREFS_1" => "{}"}
# ```
module Crystalfaux::Launcher
  # The largest value of one `CAMOU_CONFIG_n` or `CAMOU_PREFS_n` variable, in
  # bytes (Camoufox `pythonlib/camoufox/utils.py` uses 32,767; 2,047 on
  # Windows, which crystalfaux does not support).
  CHUNK_SIZE = 32_767

  # Returns the browser arguments for *options*, in the order of Playwright's
  # `server/firefox/firefox.ts`.
  def self.arguments(options : Options, profile_dir : String) : Array(String)
    arguments = ["-no-remote"]
    if options.headless
      arguments << "-headless"
    else
      arguments.push("-wait-for-browser", "-foreground")
    end
    arguments.push("-profile", profile_dir, "-juggler-pipe")
    arguments.concat(options.args)
    arguments << "-silent"
  end

  # The prefixes of the variables that carry the config and prefs. The
  # launcher removes inherited ones, because Camoufox joins every
  # `CAMOU_CONFIG_n` it finds (`additions/camoucfg/MaskConfig.hpp`, which
  # also reads an unchunked `CAMOU_CONFIG`), and `settings/camoufox.cfg`
  # does the same for `CAMOU_PREFS_n`. A stale `CAMOU_CONFIG_3` from the
  # parent would be appended to a two-chunk config.
  RESERVED_PREFIXES = {"CAMOU_CONFIG", "CAMOU_PREFS"}

  # Returns the complete environment of the browser for *options*: *base*
  # without inherited `CAMOU_CONFIG*` and `CAMOU_PREFS*` variables, then the
  # config and prefs as JSON chunks, then `options.env`.
  #
  # The prefs must travel here, not in `Browser.enable`: `camoufox.cfg`
  # applies them at startup, before Firefox caches some of them. Only
  # Camoufox builds newer than the supported range read `CAMOU_PREFS_n`;
  # the supported `152.0.4-beta.30` and `beta.31` builds ignore it, so the
  # prefs have no effect there (see `Options`).
  #
  # Migration: earlier versions of this method returned only the variables to
  # add (the chunks and `options.env`), and the child inherited the rest.
  # It now returns the complete child environment, and `BrowserProcess`
  # spawns with `clear_env: true`. A caller that wants the old override
  # map passes an empty base:
  #
  # ```
  # Crystalfaux::Launcher.environment(options, base: {} of String => String)
  # # => {"CAMOU_CONFIG_1" => "{}", "CAMOU_PREFS_1" => "{}"}
  # ```
  def self.environment(options : Options, base : Hash(String, String) = ENV.to_h) : Hash(String, String)
    base.reject { |name, _| RESERVED_PREFIXES.any? { |prefix| name.starts_with?(prefix) } }
      .merge!(chunk("CAMOU_CONFIG", options.config.to_json))
      .merge!(chunk("CAMOU_PREFS", options.prefs.to_json))
      .merge!(options.env)
  end

  # Splits *payload* into `<prefix>_1..N` variables of at most `CHUNK_SIZE`
  # bytes each, and never inside a UTF-8 character.
  #
  # Python slices a `str` by characters, so its chunks can exceed 32,767
  # bytes when the JSON holds non-ASCII text. This counts bytes on purpose:
  # the limit is on the environment value, which is bytes. Camoufox joins
  # the chunks before it parses them, so both splits give the same JSON.
  #
  # ```
  # Crystalfaux::Launcher.chunk("CAMOU_CONFIG", %({"a":1}))
  # # => {"CAMOU_CONFIG_1" => %({"a":1})}
  # ```
  def self.chunk(prefix : String, payload : String) : Hash(String, String)
    chunks = [] of String
    current = String::Builder.new
    payload.each_char do |char|
      if current.bytesize + char.bytesize > CHUNK_SIZE
        chunks << current.to_s
        current = String::Builder.new
      end
      current << char
    end
    chunks << current.to_s if current.bytesize > 0
    chunks.each.with_index(1).to_h { |chunk, index| {"#{prefix}_#{index}", chunk} }
  end
end
