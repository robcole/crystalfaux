require "../../spec_helper"
require "digest/sha256"

private PROTOCOL_DIR = File.expand_path("../../../protocol", __DIR__)

# Writes a Camoufox install directory with *version_json* as its
# `version.json` and returns its path.
private def install_dir(version_json : String?) : String
  directory = File.tempname("crystalfaux-install")
  Dir.mkdir(directory)
  File.write(File.join(directory, "version.json"), version_json) if version_json
  directory
end

private def check(version_json : String?) : SemanticVersion
  directory = install_dir(version_json)
  Crystalfaux::Protocol.check_install(directory)
ensure
  FileUtils.rm_rf(directory) if directory
end

describe Crystalfaux::Protocol::Vendored do
  it "records the checksum of the vendored Protocol.js" do
    contents = File.read(File.join(PROTOCOL_DIR, "Protocol.js"))

    Digest::SHA256.hexdigest(contents).should eq(Crystalfaux::Protocol::VENDORED.sha256)
  end

  it "records the Camoufox build the file came from" do
    vendored = Crystalfaux::Protocol::VENDORED

    vendored.camoufox_version.should eq("152.0.4")
    vendored.camoufox_build.should eq("beta.31")
    vendored.commit.should match(/\A[0-9a-f]{40}\z/)
    vendored.supports?(SemanticVersion.parse("152.0.4-beta.31")).should be_true
  end
end

describe "Crystalfaux::Protocol.check_install" do
  it "returns the version of a supported install" do
    check(%({"version":"152.0.4","build":"beta.31"})).should eq(SemanticVersion.parse("152.0.4-beta.31"))
    check(%({"version":"152.0.4","build":"beta.30"})).should eq(SemanticVersion.parse("152.0.4-beta.30"))
  end

  it "rejects builds outside the vendored range" do
    {"beta.29", "beta.32"}.each do |build|
      expect_raises(Crystalfaux::UnsupportedBrowserError, /152\.0\.4-#{build}.*152\.0\.4-beta\.30.*152\.0\.4-beta\.31/) do
        check(%({"version":"152.0.4","build":"#{build}"}))
      end
    end
    expect_raises(Crystalfaux::UnsupportedBrowserError, /156\.0\.1-beta\.1/) do
      check(%({"version":"156.0.1","build":"beta.1"}))
    end
  end

  it "rejects an install without a valid version.json" do
    expect_raises(Crystalfaux::UnsupportedBrowserError, /version\.json/) { check(nil) }
    expect_raises(Crystalfaux::UnsupportedBrowserError, /version\.json/) { check("not json") }
    expect_raises(Crystalfaux::UnsupportedBrowserError, /version\.json/) { check(%({"build":"beta.31"})) }
  end
end
