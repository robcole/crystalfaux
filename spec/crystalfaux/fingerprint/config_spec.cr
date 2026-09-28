require "../../spec_helper"

private alias Config = Crystalfaux::Fingerprint::Config
private alias OS = Crystalfaux::Fingerprint::OS
private alias Screen = Crystalfaux::Fingerprint::Screen

private MAC_UA     = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:152.0) Gecko/20100101 Firefox/152.0"
private WINDOWS_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:152.0) Gecko/20100101 Firefox/152.0"
private LINUX_UA   = "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:152.0) Gecko/20100101 Firefox/152.0"

private def voice(**fields) : Hash(String, JSON::Any)
  base = {"lang" => "en-US", "name" => "Samantha", "voiceUri" => "urn:samantha", "isDefault" => true, "isLocalService" => true}
  JSON.parse(base.merge(fields.to_h.transform_keys(&.to_s)).to_json).as_h
end

describe Crystalfaux::Fingerprint::Config do
  describe ".from_json" do
    it "accepts a CAMOU_CONFIG object whose keys and types match properties.json" do
      config = Config.from_json(<<-JSON)
        {"navigator.userAgent": "UA", "screen.width": 1512, "window.devicePixelRatio": 2,
         "screen.pageXOffset": 0.5, "window.screenX": -4, "fonts": ["Arial"],
         "webGl:parameters": {"3379": 16384}, "navigator.cookieEnabled": true,
         "navigator.hardwareConcurrency": 8.0}
        JSON

      config["screen.width"].should eq(JSON::Any.new(1512_i64))
      config["fonts"].should eq(JSON.parse(%(["Arial"])))
      config["timezone"]?.should be_nil
    end

    it "rejects a key that properties.json does not list" do
      expect_raises(Crystalfaux::ConfigError, /Unknown config key "screen\.depth"/) do
        Config.from_json(%({"screen.width": 1512, "screen.depth": 24}))
      end
    end

    it "rejects a value of the wrong type" do
      {
        %({"screen.width": "1512"})         => /screen\.width.*uint/,
        %({"screen.width": -1})             => /screen\.width.*uint/,
        %({"screen.width": 1512.5})         => /screen\.width.*uint/,
        %({"window.screenX": true})         => /window\.screenX.*int/,
        %({"navigator.cookieEnabled": 1})   => /navigator\.cookieEnabled.*bool/,
        %({"window.devicePixelRatio": "2"}) => /window\.devicePixelRatio.*double/,
        %({"fonts": "Arial"})               => /fonts.*array/,
        %({"webGl:parameters": []})         => /webGl:parameters.*dict/,
        %({"navigator.userAgent": null})    => /navigator\.userAgent.*str/,
      }.each do |json, message|
        expect_raises(Crystalfaux::ConfigError, message) { Config.from_json(json) }
      end
    end

    it "requires every voice to be a complete voice object, as MaskConfig::MVoices" do
      Config.new({"voices" => JSON::Any.new([JSON::Any.new(voice)])})["voices"].as_a.size.should eq(1)

      expect_raises(Crystalfaux::ConfigError, /voices\[0\].*object/) do
        Config.from_json(%({"voices": ["Samantha:en-US:local"]}))
      end
      incomplete = voice.reject("voiceUri")
      expect_raises(Crystalfaux::ConfigError, /voices\[1\].*voiceUri/) do
        Config.new({"voices" => JSON::Any.new([JSON::Any.new(voice), JSON::Any.new(incomplete)])})
      end
    end

    it "rejects a document that is not a JSON object" do
      expect_raises(Crystalfaux::ConfigError, /JSON object/) { Config.from_json("[]") }
      expect_raises(Crystalfaux::ConfigError, /JSON/) { Config.from_json("{") }
    end
  end

  describe ".new" do
    it "takes a Crystal hash of plain values" do
      config = Config.new({"screen.width" => 1280, "navigator.platform" => "MacIntel"})

      config.to_h.should eq({"screen.width" => JSON::Any.new(1280_i64), "navigator.platform" => JSON::Any.new("MacIntel")})
    end

    it "keeps its values when the caller changes the hash" do
      values = {"screen.width" => JSON::Any.new(1280_i64)}
      config = Config.new(values)
      values["screen.width"] = JSON::Any.new("wrong")
      config.to_h["screen.height"] = JSON::Any.new(1_i64)

      config.to_h.should eq({"screen.width" => JSON::Any.new(1280_i64)})
    end
  end

  describe "#merge" do
    it "returns a validated config with the given keys replaced" do
      config = Config.new({"screen.width" => 1280, "timezone" => "UTC"})

      merged = config.merge({"timezone" => JSON::Any.new("Europe/Berlin")})

      merged["timezone"].should eq(JSON::Any.new("Europe/Berlin"))
      merged["screen.width"].should eq(JSON::Any.new(1280_i64))
      config["timezone"].should eq(JSON::Any.new("UTC"))
      expect_raises(Crystalfaux::ConfigError, /Unknown/) { config.merge({"nope" => JSON::Any.new(1_i64)}) }
    end
  end

  describe ".for" do
    it "fills the navigator, screen, window and font keys of a macOS fingerprint" do
      config = Config.for(os: OS::Mac, screen: Screen.new(1512, 982), user_agent: MAC_UA)

      config.to_h.reject("fonts").should eq(JSON.parse({
        "navigator.userAgent"  => MAC_UA,
        "headers.User-Agent"   => MAC_UA,
        "navigator.platform"   => "MacIntel",
        "navigator.oscpu"      => "Intel Mac OS X 10.15",
        "navigator.appVersion" => "5.0 (Macintosh)",
        "screen.width"         => 1512,
        "screen.height"        => 982,
        "screen.availWidth"    => 1512,
        "screen.availHeight"   => 957,
        "window.outerWidth"    => 1512,
        "window.outerHeight"   => 957,
        "window.screenX"       => 0,
        "window.screenY"       => 0,
      }.to_json).as_h)
      fonts = config["fonts"].as_a.map(&.as_s)
      fonts.should eq(OS::Mac.fonts)
      fonts.should contain("PingFang SC")
      fonts.should_not contain("Segoe UI")
    end

    it "derives the platform and oscpu of Windows and Linux from the user agent" do
      windows = Config.for(os: OS::Windows, screen: Screen.new(1920, 1080), user_agent: WINDOWS_UA)
      linux = Config.for(os: OS::Linux, screen: Screen.new(1920, 1080), user_agent: LINUX_UA)

      {windows["navigator.platform"], windows["navigator.oscpu"], windows["navigator.appVersion"]}
        .should eq({JSON::Any.new("Win32"), JSON::Any.new("Windows NT 10.0; Win64; x64"), JSON::Any.new("5.0 (Windows)")})
      windows["screen.availHeight"].should eq(JSON::Any.new(1040_i64))
      windows["fonts"].as_a.map(&.as_s).should contain("Segoe UI")
      {linux["navigator.platform"], linux["navigator.oscpu"], linux["navigator.appVersion"]}
        .should eq({JSON::Any.new("Linux x86_64"), JSON::Any.new("Linux x86_64"), JSON::Any.new("5.0 (X11; Ubuntu)")})
      linux["screen.availHeight"].should eq(JSON::Any.new(1053_i64))
      linux["fonts"].as_a.map(&.as_s).should contain("Arimo")
    end

    it "centres a smaller window on the screen" do
      config = Config.for(os: OS::Windows, screen: Screen.new(1920, 1080), user_agent: WINDOWS_UA,
        window: Screen.new(1280, 800))

      {config["window.outerWidth"], config["window.outerHeight"]}.should eq({JSON::Any.new(1280_i64), JSON::Any.new(800_i64)})
      {config["window.screenX"], config["window.screenY"]}.should eq({JSON::Any.new(320_i64), JSON::Any.new(140_i64)})
    end

    it "shrinks a window that does not fit into the available area" do
      config = Config.for(os: OS::Mac, screen: Screen.new(1440, 900), user_agent: MAC_UA, window: Screen.new(1600, 900))

      {config["window.outerWidth"], config["window.outerHeight"]}.should eq({JSON::Any.new(1440_i64), JSON::Any.new(875_i64)})
      {config["window.screenX"], config["window.screenY"]}.should eq({JSON::Any.new(0_i64), JSON::Any.new(0_i64)})
    end

    it "rejects a user agent of another OS" do
      expect_raises(Crystalfaux::ConfigError, /user agent.*Windows.*not Mac/) do
        Config.for(os: OS::Mac, screen: Screen.new(1440, 900), user_agent: WINDOWS_UA)
      end
      expect_raises(Crystalfaux::ConfigError, /OS of the user agent/) do
        Config.for(os: OS::Mac, screen: Screen.new(1440, 900), user_agent: "curl/8.0")
      end
    end

    it "rejects a screen without area" do
      expect_raises(Crystalfaux::ConfigError, /screen/) do
        Config.for(os: OS::Mac, screen: Screen.new(0, 900), user_agent: MAC_UA)
      end
    end
  end
end
