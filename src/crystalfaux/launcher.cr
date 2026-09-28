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
# Crystalfaux::Launcher.environment(options)
# # => {"CAMOU_CONFIG_1" => "{}", "CAMOU_PREFS_1" => "{}"}
# ```
module Crystalfaux::Launcher
  # The largest value of one `CAMOU_CONFIG_n` or `CAMOU_PREFS_n` variable, in
  # characters (Camoufox `pythonlib/camoufox/utils.py`; 2,047 on Windows,
  # which crystalfaux does not support).
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

  # Returns the environment variables to add for *options*: the config and
  # prefs as JSON chunks, then `options.env`.
  #
  # Camoufox joins `CAMOU_CONFIG_1..N` back into one JSON document at
  # startup; its `camoufox.cfg` does the same for `CAMOU_PREFS_1..N`.
  def self.environment(options : Options) : Hash(String, String)
    chunk("CAMOU_CONFIG", options.config.to_json)
      .merge!(chunk("CAMOU_PREFS", options.prefs.to_json))
      .merge!(options.env)
  end

  # Splits *payload* into `<prefix>_1..N` variables of at most `CHUNK_SIZE`
  # characters each.
  #
  # The split counts characters, as Python slices a `str`, so a multibyte
  # character never breaks across two variables.
  def self.chunk(prefix : String, payload : String) : Hash(String, String)
    payload.each_char.each_slice(CHUNK_SIZE).with_index(1).to_h do |chars, index|
      {"#{prefix}_#{index}", chars.join}
    end
  end
end
