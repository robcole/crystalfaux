require "../spec_helper"

private alias Fetch = Crystalfaux::Fetch

private MAC_ARM = Fetch::Platform.new("mac", "arm64")

private def asset(name : String, digest : String? = "sha256:7b8d12d61de9a9fbd3ce9c034399ba5307e44f4d8951873cc53ad39d20957737",
                  created_at : String = "2026-09-24T21:57:25Z") : Fetch::Asset
  Fetch::Asset.from_json({
    id: 42, name: name, size: 1234, digest: digest,
    browser_download_url: "https://example.test/#{name}",
    created_at: created_at, updated_at: created_at,
  }.to_json)
end

private def release(names : Array(String), prerelease : Bool = false) : Fetch::Release
  Fetch::Release.new(prerelease, names.map { |name| asset(name) })
end

private def builds(*names : String) : Array(Fetch::Build)
  Fetch.builds([release(names.to_a)], MAC_ARM)
end

describe Crystalfaux::Fetch do
  describe Crystalfaux::Fetch::Platform do
    it "matches the asset pattern of its own OS and architecture only" do
      mac = Fetch::Platform.new("mac", "arm64")
      linux = Fetch::Platform.new("lin", "x86_64")

      mac.match("camoufox-152.0.4-beta.31-mac.arm64.zip").should eq({"152.0.4", "beta.31"})
      mac.match("camoufox-152.0.4-beta.31-mac.x86_64.zip").should be_nil
      mac.match("camoufox-152.0.4-beta.31-lin.arm64.zip").should be_nil
      linux.match("camoufox-152.0.4-beta.31-lin.x86_64.zip").should eq({"152.0.4", "beta.31"})
      linux.match("fonts-bundle-v1.tar.xz").should be_nil
      linux.match("camoufox-152.0.4-beta.31-lin.x86_64.zip.sig").should be_nil
    end

    it "names the platform it was compiled for" do
      platform = Fetch::Platform.current
      {% if flag?(:darwin) %}
        platform.os.should eq("mac")
      {% else %}
        platform.os.should eq("lin")
      {% end %}
      {% if flag?(:aarch64) %}
        platform.arch.should eq("arm64")
      {% elsif flag?(:x86_64) %}
        platform.arch.should eq("x86_64")
      {% end %}
    end
  end

  describe ".builds" do
    it "keeps the assets of this platform, newest first" do
      found = Fetch.builds([
        release(["camoufox-152.0.4-beta.30-mac.arm64.zip", "camoufox-152.0.4-beta.30-lin.arm64.zip"]),
        release(["camoufox-152.0.4-beta.31-mac.arm64.zip", "fonts-bundle-v1.tar.xz"]),
        release(["camoufox-152.0.4-beta.9-mac.arm64.zip"], prerelease: true),
      ], MAC_ARM)

      found.map(&.name).should eq(["152.0.4-beta.31", "152.0.4-beta.30", "152.0.4-beta.9"])
      found.map(&.prerelease?).should eq([false, false, true])
    end

    it "skips asset names that are not semantic versions" do
      builds("camoufox-152.0.4-nightly!-mac.arm64.zip").should be_empty
    end
  end

  describe Crystalfaux::Fetch::Build do
    it "names its install directory <version>-<build>-<sha8>" do
      builds("camoufox-152.0.4-beta.31-mac.arm64.zip").first.directory_name
        .should eq("152.0.4-beta.31-7b8d12d6")
    end

    it "omits the sha8 suffix when the release has no digest" do
      build = Fetch.builds([Fetch::Release.new(false, [asset("camoufox-152.0.4-beta.31-mac.arm64.zip", digest: nil)])], MAC_ARM).first
      build.sha256.should be_nil
      build.directory_name.should eq("152.0.4-beta.31")
    end

    it "writes version.json in the shape of the Camoufox Python package" do
      build = builds("camoufox-152.0.4-beta.31-mac.arm64.zip").first

      JSON.parse(build.version_json).should eq(JSON.parse({
        version:          "152.0.4",
        build:            "beta.31",
        prerelease:       false,
        asset_id:         42,
        asset_size:       1234,
        asset_updated_at: "2026-09-24T21:57:25Z",
        sha256:           "7b8d12d61de9a9fbd3ce9c034399ba5307e44f4d8951873cc53ad39d20957737",
        created_at:       "2026-09-24T21:57:25Z",
      }.to_json))
    end
  end

  describe ".select" do
    available = builds(
      "camoufox-152.0.4-beta.32-mac.arm64.zip",
      "camoufox-152.0.4-beta.31-mac.arm64.zip",
      "camoufox-152.0.4-beta.30-mac.arm64.zip",
      "camoufox-152.0.4-beta.29-mac.arm64.zip",
    )

    it "picks the newest build in the supported range" do
      Fetch.select(available).name.should eq("152.0.4-beta.31")
    end

    it "picks the newest build of all with allow_unsupported" do
      Fetch.select(available, allow_unsupported: true).name.should eq("152.0.4-beta.32")
    end

    it "picks the requested version, by full name or by build" do
      Fetch.select(available, "152.0.4-beta.30").name.should eq("152.0.4-beta.30")
      Fetch.select(available, "beta.30").name.should eq("152.0.4-beta.30")
    end

    it "refuses a requested version outside the supported range" do
      expect_raises(Crystalfaux::UnsupportedBrowserError, /152\.0\.4-beta\.29 is not supported/) do
        Fetch.select(available, "152.0.4-beta.29")
      end
      Fetch.select(available, "152.0.4-beta.29", allow_unsupported: true).name.should eq("152.0.4-beta.29")
    end

    it "refuses when no build is in the supported range" do
      expect_raises(Crystalfaux::UnsupportedBrowserError, /No Camoufox build.*152\.0\.4-beta\.30 to 152\.0\.4-beta\.31.*newest is 152\.0\.4-beta\.32/) do
        Fetch.select(builds("camoufox-152.0.4-beta.32-mac.arm64.zip"))
      end
    end

    it "fails when the requested version is not released for this platform" do
      expect_raises(Crystalfaux::FetchError, /No Camoufox build 152\.0\.4-beta\.99 for mac arm64/) do
        Fetch.select(available, "152.0.4-beta.99", platform: MAC_ARM)
      end
    end

    it "fails when there are no builds for this platform" do
      expect_raises(Crystalfaux::FetchError, /No Camoufox build for mac arm64/) do
        Fetch.select([] of Fetch::Build, platform: MAC_ARM)
      end
    end
  end
end
