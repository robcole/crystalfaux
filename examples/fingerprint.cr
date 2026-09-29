# Launches Camoufox with a fingerprint config, then reads the values back
# from a page. The config also turns on the page's own JavaScript world
# for `world: :main`.
#
# With no argument, it loads the committed macOS desktop fingerprint from
# `examples/fingerprints/`. Give the path of another config JSON to use it;
# the prefs come from `<name>.prefs.json` beside it, when that file exists.
#
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/fingerprint.cr
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/fingerprint.cr -- my-config.json
require "../src/crystalfaux"

config_path = Path[ARGV[0]? || Path[__DIR__, "fingerprints", "macos-desktop.json"]]
prefs_path = config_path.parent / "#{config_path.stem}.prefs.json"

# `Config.from_json` checks every key and value type against Camoufox's
# property list. `merge` adds other keys.
config = Crystalfaux::Fingerprint::Config
  .from_json(File.read(config_path))
  .merge({"allowMainWorld" => JSON::Any.new(true)})
prefs = File.exists?(prefs_path) ? JSON.parse(File.read(prefs_path)).as_h : {} of String => JSON::Any

# An unknown key raises `ConfigError` instead of being ignored.
begin
  config.merge({"navigator.userAgnet" => JSON::Any.new("typo")})
rescue ex : Crystalfaux::ConfigError
  puts "Rejected: #{ex.message}"
end

browser = Crystalfaux::Browser.launch(config: config, prefs: prefs)
begin
  page = browser.new_context.new_page
  page.goto("data:text/html,<script>window.appState = {user: 'Ada'}</script>")

  puts "config: #{config_path}"
  puts "userAgent: #{page.evaluate("navigator.userAgent")}"
  puts "platform: #{page.evaluate("navigator.platform")}"
  puts "screen: #{page.evaluate("[screen.width, screen.height, screen.availHeight]").to_json}"
  puts "webdriver: #{page.evaluate("navigator.webdriver")}"
  puts "hardwareConcurrency: #{page.evaluate("navigator.hardwareConcurrency")}"

  # The isolated world does not see the page's globals; the main world does.
  puts "appState (isolated): #{page.evaluate("window.appState").to_json}"
  puts "appState (main): #{page.evaluate("window.appState", world: :main).to_json}"
ensure
  browser.close
end
