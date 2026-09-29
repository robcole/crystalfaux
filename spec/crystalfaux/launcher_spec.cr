require "../spec_helper"

private def options(**named) : Crystalfaux::Launcher::Options
  Crystalfaux::Launcher::Options.new(**named)
end

describe Crystalfaux::Launcher do
  describe ".arguments" do
    it "builds Playwright's headless argument list" do
      Crystalfaux::Launcher.arguments(options(args: ["-width", "800"]), "/tmp/profile")
        .should eq(["-no-remote", "-headless", "-profile", "/tmp/profile",
                    "-juggler-pipe", "-width", "800", "-silent"])
    end

    it "keeps the browser in the foreground when headful" do
      Crystalfaux::Launcher.arguments(options(headless: false), "/tmp/profile")
        .should eq(["-no-remote", "-wait-for-browser", "-foreground",
                    "-profile", "/tmp/profile", "-juggler-pipe", "-silent"])
    end
  end

  describe ".check_prefs" do
    it "accepts bools, strings and integers from Int32::MIN to Int32::MAX" do
      Crystalfaux::Launcher.check_prefs({
        "a.bool"   => JSON::Any.new(false),
        "a.string" => JSON::Any.new("fr-FR, fr"),
        "a.min"    => JSON::Any.new(Int32::MIN.to_i64),
        "a.max"    => JSON::Any.new(Int32::MAX.to_i64),
      })
    end

    {
      "a fraction"           => JSON::Any.new(1.9),
      "an integral float"    => JSON::Any.new(1.0),
      "one past Int32::MAX"  => JSON::Any.new(Int32::MAX.to_i64 + 1),
      "one below Int32::MIN" => JSON::Any.new(Int32::MIN.to_i64 - 1),
      "Int64::MAX"           => JSON::Any.new(Int64::MAX),
      "null"                 => JSON::Any.new(nil),
      "an array"             => JSON.parse("[1]"),
      "an object"            => JSON.parse(%({"a": 1})),
    }.each do |kind, value|
      it "rejects #{kind} and names the pref" do
        prefs = {"ok.pref" => JSON::Any.new(true), "bad.pref" => value}
        expect_raises(Crystalfaux::PrefError, /"bad\.pref"/) { Crystalfaux::Launcher.check_prefs(prefs) }
      end
    end
  end

  describe ".environment" do
    it "rejects a pref that the browser cannot set" do
      expect_raises(Crystalfaux::PrefError, /"media\.volume_scale"/) do
        Crystalfaux::Launcher.environment(options(prefs: {"media.volume_scale" => JSON::Any.new(0.5)}))
      end
    end

    it "encodes config and prefs as JSON chunks, then adds the caller's env" do
      env = Crystalfaux::Launcher.environment(options(
        config: {"navigator.platform" => JSON::Any.new("MacIntel")},
        prefs: {"media.autoplay.default" => JSON::Any.new(0_i64)},
        env: {"MOZ_LOG" => "none"},
      ), base: {} of String => String)

      env.should eq({
        "CAMOU_CONFIG_1" => %({"navigator.platform":"MacIntel"}),
        "CAMOU_PREFS_1"  => %({"media.autoplay.default":0}),
        "MOZ_LOG"        => "none",
      })
    end

    it "sends empty objects when there is no config or prefs" do
      Crystalfaux::Launcher.environment(options, base: {} of String => String)
        .should eq({"CAMOU_CONFIG_1" => "{}", "CAMOU_PREFS_1" => "{}"})
    end

    it "lets the caller's env override a generated chunk" do
      env = Crystalfaux::Launcher.environment(options(env: {"CAMOU_PREFS_1" => "{\"a\":1}"}))
      env["CAMOU_PREFS_1"].should eq(%({"a":1}))
    end

    it "starts from the base environment without inherited CAMOU_CONFIG and CAMOU_PREFS variables" do
      base = {
        "PATH"           => "/usr/bin",
        "HOME"           => "/Users/me",
        "CAMOU_CONFIG"   => %({"stale":true}),
        "CAMOU_CONFIG_1" => %({"navigator.platform":),
        "CAMOU_CONFIG_2" => %("Win32"}),
        "CAMOU_PREFS_1"  => %({"stale":),
        "CAMOU_PREFS_7"  => "1}",
        "CAMOUFLAGE"     => "kept",
      }

      env = Crystalfaux::Launcher.environment(options(config: {"screen.width" => JSON::Any.new(1280_i64)}), base: base)

      env.should eq({
        "PATH"           => "/usr/bin",
        "HOME"           => "/Users/me",
        "CAMOUFLAGE"     => "kept",
        "CAMOU_CONFIG_1" => %({"screen.width":1280}),
        "CAMOU_PREFS_1"  => "{}",
      })
    end

    it "starts from the process environment by default" do
      env = Crystalfaux::Launcher.environment(options)

      env["PATH"]?.should eq(ENV["PATH"]?)
      env.keys.select(&.starts_with?("CAMOU_")).sort!.should eq(["CAMOU_CONFIG_1", "CAMOU_PREFS_1"])
    end
  end

  describe ".chunk" do
    size = Crystalfaux::Launcher::CHUNK_SIZE

    it "allows 32,767 bytes per chunk, as camoufox/utils.py" do
      size.should eq(32_767)
    end

    it "keeps a payload of exactly one chunk in CAMOU_CONFIG_1" do
      Crystalfaux::Launcher.chunk("CAMOU_CONFIG", "x" * size)
        .should eq({"CAMOU_CONFIG_1" => "x" * size})
    end

    it "splits one byte past the boundary into a second chunk" do
      Crystalfaux::Launcher.chunk("CAMOU_CONFIG", "x" * size + "y")
        .should eq({"CAMOU_CONFIG_1" => "x" * size, "CAMOU_CONFIG_2" => "y"})
    end

    it "moves a multibyte character that would cross the byte limit to the next chunk" do
      chunks = Crystalfaux::Launcher.chunk("CAMOU_PREFS", "x" * (size - 1) + "é")

      chunks.should eq({"CAMOU_PREFS_1" => "x" * (size - 1), "CAMOU_PREFS_2" => "é"})
    end
  end

  describe ".environment chunks" do
    it "keeps every value within the byte limit and joins back losslessly" do
      text = "Schriftart ü 字体 🦊 " * 3_000
      options = options(
        config: {"fonts" => JSON::Any.new(text)},
        prefs: {"intl.accept_languages" => JSON::Any.new(text)},
      )
      env = Crystalfaux::Launcher.environment(options, base: {} of String => String)

      {"CAMOU_CONFIG" => options.config, "CAMOU_PREFS" => options.prefs}.each do |prefix, source|
        chunks = env.select { |name, _| name.starts_with?("#{prefix}_") }
        chunks.size.should be > 2
        chunks.keys.should eq((1..chunks.size).map { |i| "#{prefix}_#{i}" })
        chunks.values.all? { |value| value.bytesize <= Crystalfaux::Launcher::CHUNK_SIZE }.should be_true
        chunks.values.all?(&.valid_encoding?).should be_true
        chunks.values.join.should eq(source.to_json)
      end
    end
  end
end
