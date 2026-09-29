require "compress/zip"
require "digest/sha256"
require "file_utils"
require "random/secure"

module Crystalfaux::Fetch
  # Installs Camoufox builds into one directory, one subdirectory per build,
  # in the layout that `Launcher::Discovery` searches:
  #
  # ```text
  # <dir>/152.0.4-beta.31-7b8d12d6/
  #   version.json
  #   Camoufox.app/...
  # ```
  #
  # The installer downloads the archive next to the install, checks its size
  # and SHA-256, extracts it into a staging directory, writes
  # `version.json`, and then renames the staging directory into place. It
  # deletes the archive and the staging directory on success and on failure,
  # so an interrupted install leaves no directory that looks installed.
  class Installer
    # The directory that holds one subdirectory per install.
    getter dir : Path

    # *progress* receives a progress line while the archive downloads; `nil`
    # prints nothing. *dir* is expanded to an absolute, normalized path, so
    # the containment check on archive entries compares like with like.
    def initialize(dir : Path | String, @client : Client = Client.new, @progress : IO? = nil)
      @dir = Path[dir].expand
    end

    # Returns the install directory of *build* in `dir`.
    def path(build : Build) : Path
      dir / build.directory_name
    end

    # Whether *build* is installed: its directory holds a `version.json`.
    def installed?(build : Build) : Bool
      File.file?(path(build) / "version.json")
    end

    # Installs *build* and returns its install directory. Does nothing when
    # the build is already installed. Raises `FetchError` when the download
    # fails or does not match the release, or the archive is not valid.
    def install(build : Build) : Path
      target = path(build)
      if installed?(build)
        @progress.try &.puts("Camoufox #{build.name} is already installed in #{target}")
        return target
      end

      Dir.mkdir_p(dir)
      # Unique names, so two installs of one build do not share files.
      prefix = dir / ".#{build.directory_name}.#{Random::Secure.hex(4)}"
      archive = Path["#{prefix}.zip"]
      staging = Path["#{prefix}.partial"]
      begin
        download(build, archive)
        verify(build, archive)
        extract(archive, staging)
        File.write(staging / "version.json", build.version_json)
        # A directory without version.json is an earlier failed install.
        FileUtils.rm_rf(target)
        File.rename(staging, target)
      ensure
        File.delete?(archive)
        FileUtils.rm_rf(staging)
      end
      target
    end

    private def download(build : Build, archive : Path) : Nil
      name = build.asset.name
      last_step = -1_i64
      File.open(archive, "w") do |file|
        @client.download(build.asset.browser_download_url, file) do |received, total|
          total ||= build.asset.size
          step = total > 0 ? received * 100 // total : received >> 23
          next if step == last_step
          last_step = step
          report(name, received, total)
        end
      end
      @progress.try &.puts
    end

    private def report(name : String, received : Int64, total : Int64) : Nil
      progress = @progress
      return unless progress
      megabytes = ->(bytes : Int64) { (bytes / 1_000_000).round(1) }
      percent = total > 0 ? received * 100 // total : 0
      progress << "\rDownloading " << name << ": " << percent << "% ("
      progress << megabytes.call(received) << " of " << megabytes.call(total) << " MB)"
      progress.flush
    end

    private def verify(build : Build, archive : Path) : Nil
      size = File.size(archive)
      unless size == build.asset.size
        raise FetchError.new("Size mismatch for #{build.asset.name}: expected #{build.asset.size} bytes, got #{size}")
      end
      expected = build.sha256
      return unless expected
      actual = Digest::SHA256.new.file(archive).hexfinal
      return if actual == expected
      raise FetchError.new("SHA-256 mismatch for #{build.asset.name}: expected #{expected}, got #{actual}")
    end

    private def extract(archive : Path, staging : Path) : Nil
      Dir.mkdir(staging)
      Compress::Zip::File.open(archive) do |zip|
        zip.entries.each { |entry| extract_entry(entry, staging) }
      end
    rescue error : Compress::Zip::Error | Compress::Deflate::Error
      raise FetchError.new("Cannot extract #{archive}: #{error.message}")
    end

    # *staging* is absolute and normalized (see `#initialize`), so a
    # normalized entry path that does not start with it leaves the install.
    private def extract_entry(entry : Compress::Zip::File::Entry, staging : Path) : Nil
      path = (staging / entry.filename).normalize
      unless path.parts[0, staging.parts.size] == staging.parts && path.parts.size > staging.parts.size
        raise FetchError.new("Archive entry #{entry.filename} is outside the install directory")
      end
      if entry.dir?
        Dir.mkdir_p(path)
      else
        Dir.mkdir_p(path.parent)
        entry.open { |input| File.open(path, "w") { |output| IO.copy(input, output) } }
      end
      # `Compress::Zip` does not keep Unix modes. Camoufox
      # `pythonlib/camoufox/multiversion.py` runs `chmod -R 755` on the
      # install for the same reason.
      File.chmod(path, 0o755)
    end
  end
end
