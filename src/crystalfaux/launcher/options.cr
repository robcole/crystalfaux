require "json"

module Crystalfaux::Launcher
  # Describes how to launch one Camoufox process.
  #
  # ```
  # options = Crystalfaux::Launcher::Options.new(
  #   headless: true,
  #   config: {"navigator.platform" => JSON::Any.new("MacIntel")},
  #   prefs: {"media.autoplay.default" => JSON::Any.new(0_i64)},
  # )
  # browser = Crystalfaux::Launcher::BrowserProcess.launch(options)
  # ```
  #
  # - *executable*: the Camoufox binary. When `nil`, `Discovery.executable`
  #   finds it.
  # - *profile_dir*: a profile directory that the caller owns. When `nil`,
  #   `BrowserProcess` creates a temporary profile and removes it on close.
  # - *args*: extra browser arguments, added before `-silent`.
  # - *config*: the Camoufox fingerprint config, sent as `CAMOU_CONFIG_n`.
  #   It is not validated here; `Browser.launch(config:)` takes a validated
  #   `Fingerprint::Config`.
  # - *prefs*: Firefox preferences, sent as `CAMOU_PREFS_n`.
  # - *env*: extra environment variables. They override generated ones.
  #
  # Copies share the same `Array` and `Hash` objects. Use `#copy_with` with
  # new collections to change them independently.
  record Options,
    executable : String? = nil,
    headless : Bool = true,
    profile_dir : String? = nil,
    args : Array(String) = [] of String,
    config : Hash(String, JSON::Any) = {} of String => JSON::Any,
    prefs : Hash(String, JSON::Any) = {} of String => JSON::Any,
    env : Hash(String, String) = {} of String => String
end
