require "../spec_helper"
require "../../src/crystalfaux/cli"
require "file_utils"

private record Run, status : Int32, stdout : String, stderr : String

private def platform_asset(build : String) : String
  platform = Crystalfaux::Fetch::Platform.current
  "camoufox-152.0.4-#{build}-#{platform.os}.#{platform.arch}.zip"
end

# Serves one release with the builds *builds* for this platform.
private def serve_releases(github : FakeGitHub, builds : Array(String)) : Nil
  archive = zip_archive({Crystalfaux::Launcher::Discovery::EXECUTABLE => "#!/bin/sh\n"})
  assets = builds.map do |build|
    name = platform_asset(build)
    github.serve("/download/#{name}", archive)
    release_asset(name, github.url("/download/#{name}"), archive)
  end
  github.serve("/repos/daijro/camoufox/releases", [{prerelease: false, assets: assets}].to_json)
end

private def run_cli(github : FakeGitHub, args : Array(String)) : Run
  stdout = IO::Memory.new
  stderr = IO::Memory.new
  client = Crystalfaux::Fetch::Client.new(api: github.uri, token: nil)
  status = Crystalfaux::CLI.new(stdout, stderr, client).run(args)
  Run.new(status, stdout.to_s, stderr.to_s)
end

private def with_dir(&)
  dir = File.tempname("crystalfaux-cli")
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Crystalfaux::CLI do
  describe "fetch" do
    it "installs the newest supported build into --dir and prints its path" do
      with_fake_github do |github|
        with_dir do |dir|
          serve_releases(github, ["beta.32", "beta.31"])

          run = run_cli(github, ["fetch", "--dir", dir])

          run.status.should eq(0)
          installed = Dir.children(dir)
          installed.size.should eq(1)
          installed.first.should start_with("152.0.4-beta.31-")
          run.stdout.should eq("#{Path[dir] / installed.first}\n")
          run.stderr.should contain("Downloading")
        end
      end
    end

    it "installs a requested version" do
      with_fake_github do |github|
        with_dir do |dir|
          serve_releases(github, ["beta.31", "beta.30"])

          run_cli(github, ["fetch", "--version", "beta.30", "--dir", dir]).status.should eq(0)
          Dir.children(dir).first.should start_with("152.0.4-beta.30-")
        end
      end
    end

    it "refuses an unsupported version unless --allow-unsupported" do
      with_fake_github do |github|
        with_dir do |dir|
          serve_releases(github, ["beta.32"])

          run = run_cli(github, ["fetch", "--version", "beta.32", "--dir", dir])
          run.status.should eq(1)
          run.stderr.should contain("152.0.4-beta.32 is not supported")
          Dir.exists?(dir).should be_false

          run_cli(github, ["fetch", "--version", "beta.32", "--dir", dir, "--allow-unsupported"]).status.should eq(0)
          Dir.children(dir).first.should start_with("152.0.4-beta.32-")
        end
      end
    end
  end

  describe "list" do
    it "lists the builds for this platform with their status" do
      with_fake_github do |github|
        with_dir do |dir|
          serve_releases(github, ["beta.32", "beta.31"])
          run_cli(github, ["fetch", "--dir", dir])

          run = run_cli(github, ["list", "--dir", dir])

          run.status.should eq(0)
          run.stdout.lines.should eq([
            "152.0.4-beta.32  unsupported",
            "152.0.4-beta.31  supported  installed",
          ])
        end
      end
    end
  end

  it "prints usage and fails on an unknown command" do
    with_fake_github do |github|
      run = run_cli(github, ["bogus"])
      run.status.should eq(2)
      run.stderr.should contain("Usage: crystalfaux")
    end
  end

  it "prints usage and succeeds with --help" do
    with_fake_github do |github|
      run = run_cli(github, ["--help"])
      run.status.should eq(0)
      run.stdout.should contain("fetch")
      run.stdout.should contain("list")
    end
  end
end
