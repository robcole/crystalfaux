require "../../spec_helper"
require "file_utils"

private alias Fetch = Crystalfaux::Fetch

private ASSET_NAME = "camoufox-152.0.4-beta.31-mac.arm64.zip"
private EXECUTABLE = "Camoufox.app/Contents/MacOS/camoufox"

# Serves *archive* as the one asset of one release, and returns its build.
private def serve_build(github : FakeGitHub, archive : Bytes, digest : Bool = true, size : Int32? = nil) : Fetch::Build
  github.serve("/download/#{ASSET_NAME}", archive)
  asset = release_asset(ASSET_NAME, github.url("/download/#{ASSET_NAME}"), archive, digest)
  asset["size"] = size if size
  release = Fetch::Release.from_json({prerelease: false, assets: [asset]}.to_json)
  Fetch.builds([release], Fetch::Platform.new("mac", "arm64")).first
end

private def with_install_dir(&)
  dir = Path[File.tempname("crystalfaux-fetch")]
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

# Returns *archive* with the CRC-32 of its entry *index* changed in the
# central directory, so extracting that entry fails after it is written.
private def corrupt_checksum(archive : Bytes, index : Int32) : Bytes
  corrupt = archive.dup
  signature = Bytes[0x50, 0x4b, 0x01, 0x02]
  offsets = (0..corrupt.size - 4).select { |offset| corrupt[offset, 4] == signature }
  corrupt[offsets[index] + 16] ^= 0xff_u8
  corrupt
end

# Writes a complete install of another build into *dir*.
private def other_install(dir : Path) : Path
  other = dir / "152.0.4-beta.30-aaaaaaaa"
  Dir.mkdir_p(other)
  File.write(other / "version.json", {version: "152.0.4", build: "beta.30"}.to_json)
  other
end

private def installer(github : FakeGitHub, dir : Path, progress : IO? = nil) : Fetch::Installer
  Fetch::Installer.new(dir, Fetch::Client.new(api: github.uri, token: nil), progress)
end

describe Crystalfaux::Fetch::Installer do
  it "extracts the archive into <dir>/<version>-<build>-<sha8> with version.json" do
    with_fake_github do |github|
      with_install_dir do |dir|
        archive = zip_archive({EXECUTABLE => "#!/bin/sh\n", "Camoufox.app/Contents/Info.plist" => "plist"})
        build = serve_build(github, archive)

        path = installer(github, dir).install(build)

        path.should eq(dir / build.directory_name)
        File.read(path / "Camoufox.app/Contents/Info.plist").should eq("plist")
        File::Info.executable?(path / EXECUTABLE).should be_true
        JSON.parse(File.read(path / "version.json"))["sha256"].should eq(build.sha256)
        Dir.children(dir).should eq([build.directory_name])
      end
    end
  end

  it "installs a directory that Discovery and the version check accept" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({Crystalfaux::Launcher::Discovery::EXECUTABLE => "#!/bin/sh\n"}))

        path = installer(github, dir).install(build)

        executable = Crystalfaux::Launcher::Discovery.executable(nil, {} of String => String, dir).should_not be_nil
        Crystalfaux::Launcher::Discovery.install_dir(executable).should eq(path)
        Crystalfaux::Protocol.check_install(path).to_s.should eq("152.0.4-beta.31")
      end
    end
  end

  it "prints a progress line on the progress IO" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({EXECUTABLE => "x"}))
        progress = IO::Memory.new

        installer(github, dir, progress).install(build)

        progress.to_s.should contain("Downloading #{ASSET_NAME}")
        progress.to_s.should contain("100%")
      end
    end
  end

  it "does not download a build that is already installed" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({EXECUTABLE => "x"}))
        installer(github, dir).install(build)

        installer(github, dir).install(build).should eq(dir / build.directory_name)
        github.requests.count(&.includes?("/download/")).should eq(1)
      end
    end
  end

  it "installs without verification when the release has no digest" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({EXECUTABLE => "x"}), digest: false)
        installer(github, dir).install(build).should eq(dir / "152.0.4-beta.31")
      end
    end
  end

  it "refuses a download whose SHA-256 does not match, and leaves nothing behind" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({EXECUTABLE => "x"}))
        github.serve("/download/#{ASSET_NAME}", zip_archive({EXECUTABLE => "y"}))

        expect_raises(Crystalfaux::FetchError, /SHA-256 mismatch/) do
          installer(github, dir).install(build)
        end
        Dir.children(dir).should be_empty
      end
    end
  end

  it "refuses a download whose size does not match" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({EXECUTABLE => "x"}), digest: false, size: 1)

        expect_raises(Crystalfaux::FetchError, /Size mismatch/) do
          installer(github, dir).install(build)
        end
        Dir.children(dir).should be_empty
      end
    end
  end

  it "refuses an archive entry that leaves the install directory" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({"../escape" => "x"}))

        expect_raises(Crystalfaux::FetchError, /outside the install directory/) do
          installer(github, dir).install(build)
        end
        File.exists?(dir / "escape").should be_false
        Dir.children(dir).should be_empty
      end
    end
  end

  it "installs into a directory spelled with dot components or relative to the working directory" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({EXECUTABLE => "x"}))
        relative = Path[dir].relative_to(Dir.current)
        spellings = {
          "#{dir}/./sub/../dotted"   => dir / "dotted",
          "./#{relative}/relative/." => dir / "relative",
        }

        spellings.each do |spelling, expected|
          installer(github, Path[spelling]).install(build).should eq(expected / build.directory_name)
          File.file?(expected / build.directory_name / EXECUTABLE).should be_true
        end
      end
    end
  end

  it "refuses an archive entry that leaves an install directory spelled with dot components" do
    with_fake_github do |github|
      with_install_dir do |dir|
        build = serve_build(github, zip_archive({"../../escape" => "x"}))

        expect_raises(Crystalfaux::FetchError, /outside the install directory/) do
          installer(github, Path["#{dir}/./sub/../cache"]).install(build)
        end
        File.exists?(dir / "escape").should be_false
        Dir.children(dir / "cache").should be_empty
      end
    end
  end

  it "fails a download that ends early and leaves only the existing installs" do
    with_fake_github do |github|
      with_install_dir do |dir|
        archive = zip_archive({EXECUTABLE => "x" * 1000})
        build = serve_build(github, archive)
        github.truncate("/download/#{ASSET_NAME}", archive, sent: archive.size // 2)
        other = other_install(dir)

        expect_raises(Crystalfaux::FetchError, /ended after #{archive.size // 2} of #{archive.size} bytes/) do
          installer(github, dir).install(build)
        end
        Dir.children(dir).should eq([other.basename])
        File.file?(other / "version.json").should be_true
      end
    end
  end

  it "fails an archive that cannot be extracted and leaves no partial install" do
    with_fake_github do |github|
      with_install_dir do |dir|
        archive = zip_archive({"Camoufox.app/Contents/Info.plist" => "plist", EXECUTABLE => "x"})
        build = serve_build(github, corrupt_checksum(archive, 1))
        other = other_install(dir)

        expect_raises(Crystalfaux::FetchError, /Cannot extract/) do
          installer(github, dir).install(build)
        end
        Dir.children(dir).should eq([other.basename])
      end
    end
  end
end
