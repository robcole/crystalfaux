# Launches Camoufox with a fingerprint config, then reads the values back
# from a page. The config also turns on the page's own JavaScript world
# for `world: :main`.
#
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/fingerprint.cr
require "../src/crystalfaux"

user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:152.0) Gecko/20100101 Firefox/152.0"

# `Config.for` sets the keys that must agree: user agent, platform, screen,
# window and fonts. `merge` adds other keys; every key is checked against
# Camoufox's property list.
config = Crystalfaux::Fingerprint::Config
  .for(os: :windows, screen: Crystalfaux::Fingerprint::Screen.new(1920, 1080), user_agent: user_agent)
  .merge({
    "navigator.hardwareConcurrency" => JSON::Any.new(8_i64),
    "navigator.language"            => JSON::Any.new("en-GB"),
    "allowMainWorld"                => JSON::Any.new(true),
  })

# An unknown key raises `ConfigError` instead of being ignored.
begin
  config.merge({"navigator.userAgnet" => JSON::Any.new("typo")})
rescue ex : Crystalfaux::ConfigError
  puts "Rejected: #{ex.message}"
end

browser = Crystalfaux::Browser.launch(config: config)
begin
  page = browser.new_context.new_page
  page.goto("data:text/html,<script>window.appState = {user: 'Ada'}</script>")

  puts "userAgent: #{page.evaluate("navigator.userAgent")}"
  puts "platform: #{page.evaluate("navigator.platform")}"
  puts "screen: #{page.evaluate("[screen.width, screen.height, screen.availHeight]").to_json}"
  puts "language: #{page.evaluate("navigator.language")}"
  puts "hardwareConcurrency: #{page.evaluate("navigator.hardwareConcurrency")}"

  # The isolated world does not see the page's globals; the main world does.
  puts "appState (isolated): #{page.evaluate("window.appState").to_json}"
  puts "appState (main): #{page.evaluate("window.appState", world: :main).to_json}"
ensure
  browser.close
end
