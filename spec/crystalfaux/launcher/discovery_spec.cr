require "../../spec_helper"
require "file_utils"

private alias Discovery = Crystalfaux::Launcher::Discovery
private NO_ENV = {} of String => String

# Builds an install directory in the Camoufox cache layout:
# `<cache>/<name>/version.json` plus the executable at *relative*.
private def install(cache : Path, name : String, version : String, build : String,
                    relative : String = "camoufox") : String
  directory = cache / name
  executable = directory / relative
  Dir.mkdir_p(executable.parent)
  File.write(directory / "version.json", {version: version, build: build}.to_json)
  File.write(executable, "#!/bin/sh\n")
  File.chmod(executable, 0o755)
  executable.to_s
end

private def with_cache(&)
  cache = Path[File.tempname("crystalfaux-cache")]
  Dir.mkdir_p(cache)
  yield cache
ensure
  FileUtils.rm_rf(cache) if cache
end

describe Crystalfaux::Launcher::Discovery do
  describe ".executable" do
    it "prefers the explicit path" do
      with_cache do |cache|
        install(cache, "152.0.4-beta.31-aaaa", "152.0.4", "beta.31")
        env = {"CRYSTALFAUX_CAMOUFOX" => "/env/camoufox"}

        Discovery.executable("/explicit/camoufox", env, cache).should eq("/explicit/camoufox")
      end
    end

    it "uses CRYSTALFAUX_CAMOUFOX before CAMOUFOX_EXECUTABLE_PATH" do
      env = {"CRYSTALFAUX_CAMOUFOX" => "/a/camoufox", "CAMOUFOX_EXECUTABLE_PATH" => "/b/camoufox"}
      Discovery.executable(nil, env, Path["/nonexistent"]).should eq("/a/camoufox")
    end

    it "uses CAMOUFOX_EXECUTABLE_PATH before the cache" do
      with_cache do |cache|
        install(cache, "152.0.4-beta.31-aaaa", "152.0.4", "beta.31")
        env = {"CRYSTALFAUX_CAMOUFOX" => "", "CAMOUFOX_EXECUTABLE_PATH" => "/b/camoufox"}

        Discovery.executable(nil, env, cache).should eq("/b/camoufox")
      end
    end

    it "picks the newest install in the cache, comparing build numbers numerically" do
      with_cache do |cache|
        install(cache, "152.0.4-beta.9-aaaa", "152.0.4", "beta.9")
        newest = install(cache, "152.0.4-beta.31-bbbb", "152.0.4", "beta.31")
        install(cache, "151.0.1-beta.40-cccc", "151.0.1", "beta.40")

        Discovery.executable(nil, NO_ENV, cache, "camoufox").should eq(newest)
      end
    end

    it "finds the executable inside a macOS app bundle" do
      with_cache do |cache|
        relative = "Camoufox.app/Contents/MacOS/camoufox"
        executable = install(cache, "152.0.4-beta.31-aaaa", "152.0.4", "beta.31", relative)

        Discovery.executable(nil, NO_ENV, cache, relative).should eq(executable)
      end
    end

    it "skips installs without a readable version.json or executable" do
      with_cache do |cache|
        valid = install(cache, "150.0-beta.1-aaaa", "150.0", "beta.1")
        Dir.mkdir_p(cache / "empty")
        {"not json", %({"build":"beta.1"}), %({"version":"latest","build":"beta.1"})}.each_with_index do |json, index|
          broken = cache / "broken-#{index}"
          Dir.mkdir_p(broken)
          File.write(broken / "version.json", json)
          File.write(broken / "camoufox", "#!/bin/sh\n")
          File.chmod(broken / "camoufox", 0o755)
        end
        missing = cache / "no-binary"
        Dir.mkdir_p(missing)
        File.write(missing / "version.json", {version: "160.0.0", build: "beta.1"}.to_json)

        Discovery.executable(nil, NO_ENV, cache, "camoufox").should eq(valid)
      end
    end

    it "returns nil when nothing is found" do
      with_cache do |cache|
        Discovery.executable(nil, NO_ENV, cache, "camoufox").should be_nil
      end
      Discovery.executable(nil, NO_ENV, Path["/nonexistent"]).should be_nil
    end
  end

  describe ".install_dir" do
    it "strips the install-relative executable path" do
      Discovery.install_dir("/cache/152.0.4-beta.31-7b8d12d6/Camoufox.app/Contents/MacOS/camoufox",
        "Camoufox.app/Contents/MacOS/camoufox").should eq(Path["/cache/152.0.4-beta.31-7b8d12d6"])
      Discovery.install_dir("/cache/152.0.4-beta.31-7b8d12d6/camoufox", "camoufox")
        .should eq(Path["/cache/152.0.4-beta.31-7b8d12d6"])
    end

    it "uses the executable's directory for another layout" do
      Discovery.install_dir("/opt/build/firefox", "Camoufox.app/Contents/MacOS/camoufox")
        .should eq(Path["/opt/build"])
    end
  end

  describe ".cache_dir" do
    it "follows the per-OS cache location" do
      {% if flag?(:darwin) %}
        Discovery.cache_dir(NO_ENV, Path["/Users/me"])
          .should eq(Path["/Users/me/Library/Caches/camoufox/browsers/official"])
      {% else %}
        Discovery.cache_dir(NO_ENV, Path["/home/me"])
          .should eq(Path["/home/me/.cache/camoufox/browsers/official"])
        Discovery.cache_dir({"XDG_CACHE_HOME" => "/xdg"}, Path["/home/me"])
          .should eq(Path["/xdg/camoufox/browsers/official"])
      {% end %}
    end
  end
end
