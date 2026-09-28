require "../../spec_helper"

private def fix(os : Crystalfaux::Fingerprint::OS, **values) : Hash(String, JSON::Any)
  config = JSON.parse(values.to_h.transform_keys(&.to_s.gsub('_', '.')).to_json).as_h
  Crystalfaux::Fingerprint::Geometry.fix(config, os)
  config
end

private def ints(config : Hash(String, JSON::Any)) : Hash(String, Int64)
  config.transform_values(&.as_i64)
end

# Ported from Camoufox `pythonlib/camoufox/fingerprints.py`:
# `fix_screen_no_taskbar`, `clamp_window_dimensions`, `clamp_window_position`.
describe Crystalfaux::Fingerprint::Geometry do
  it "reserves the OS taskbar when the available area equals the screen" do
    config = fix(:windows, screen_width: 1920, screen_height: 1080, screen_availWidth: 1920,
      screen_availHeight: 1080, window_outerHeight: 1080, window_innerHeight: 990)

    ints(config).should eq({
      "screen.width" => 1920, "screen.height" => 1080, "screen.availWidth" => 1920,
      "screen.availHeight" => 1040, "window.outerHeight" => 1040, "window.innerHeight" => 950,
    })
  end

  it "keeps inner <= outer <= avail <= screen on both axes, keeping the chrome size" do
    config = fix(:mac, screen_width: 1440, screen_height: 900, screen_availWidth: 1500,
      screen_availHeight: 875, window_outerWidth: 1600, window_innerWidth: 1590,
      window_outerHeight: 870, window_innerHeight: 880)

    ints(config).should eq({
      "screen.width" => 1440, "screen.height" => 900, "screen.availWidth" => 1440,
      "screen.availHeight" => 875, "window.outerWidth" => 1440, "window.innerWidth" => 1430,
      "window.outerHeight" => 870, "window.innerHeight" => 870,
    })
  end

  it "keeps the window inside the screen" do
    config = fix(:linux, screen_width: 1920, screen_height: 1080, screen_availHeight: 1053,
      window_outerWidth: 1280, window_outerHeight: 800, window_screenX: 900, window_screenY: -20)

    {config["window.screenX"], config["window.screenY"]}.should eq({JSON::Any.new(640_i64), JSON::Any.new(0_i64)})
  end

  it "leaves a config without geometry alone" do
    fix(:mac, navigator_platform: "MacIntel").should eq({"navigator.platform" => JSON::Any.new("MacIntel")})
  end
end
