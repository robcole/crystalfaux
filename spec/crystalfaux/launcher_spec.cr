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

  describe ".environment" do
    it "encodes config and prefs as JSON chunks, then adds the caller's env" do
      env = Crystalfaux::Launcher.environment(options(
        config: {"navigator.platform" => JSON::Any.new("MacIntel")},
        prefs: {"media.autoplay.default" => JSON::Any.new(0_i64)},
        env: {"MOZ_LOG" => "none"},
      ))

      env.should eq({
        "CAMOU_CONFIG_1" => %({"navigator.platform":"MacIntel"}),
        "CAMOU_PREFS_1"  => %({"media.autoplay.default":0}),
        "MOZ_LOG"        => "none",
      })
    end

    it "sends empty objects when there is no config or prefs" do
      Crystalfaux::Launcher.environment(options)
        .should eq({"CAMOU_CONFIG_1" => "{}", "CAMOU_PREFS_1" => "{}"})
    end

    it "lets the caller's env override a generated chunk" do
      env = Crystalfaux::Launcher.environment(options(env: {"CAMOU_PREFS_1" => "{\"a\":1}"}))
      env["CAMOU_PREFS_1"].should eq(%({"a":1}))
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
      env = Crystalfaux::Launcher.environment(options)

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
