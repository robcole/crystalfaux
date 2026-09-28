require "json"
require "semantic_version"

module Crystalfaux::Launcher
  # Finds the Camoufox executable.
  #
  # The search order is:
  #
  # 1. the explicit path,
  # 2. `CRYSTALFAUX_CAMOUFOX`,
  # 3. `CAMOUFOX_EXECUTABLE_PATH`,
  # 4. the newest install in the Camoufox cache.
  #
  # Each cache install directory holds a `version.json` and the executable
  # (Camoufox `pythonlib/camoufox/pkgman.py`):
  #
  # ```text
  # ~/Library/Caches/camoufox/browsers/official/152.0.4-beta.31-7b8d12d6/
  #   version.json
  #   Camoufox.app/Contents/MacOS/camoufox
  # ```
  #
  # On Linux the directory is `~/.cache/camoufox/browsers/official/<install>/`
  # and the executable is `camoufox`.
  module Discovery
    ENV_VARS = {"CRYSTALFAUX_CAMOUFOX", "CAMOUFOX_EXECUTABLE_PATH"}

    {% if flag?(:darwin) %}
      EXECUTABLE = "Camoufox.app/Contents/MacOS/camoufox"
    {% else %}
      EXECUTABLE = "camoufox"
    {% end %}

    # Returns the path of the Camoufox executable, or `nil` when no source
    # names one. An explicit or environment path is returned as given; a
    # cache install is used only when its executable exists.
    #
    # ```
    # Discovery.executable # => "/Users/me/Library/Caches/camoufox/.../camoufox"
    # ```
    def self.executable(explicit : String? = nil, env : Hash(String, String) = ENV.to_h,
                        cache_dir : Path = cache_dir(env), relative_executable : String = EXECUTABLE) : String?
      return explicit if explicit
      ENV_VARS.each do |name|
        path = env[name]?
        return path if path && !path.empty?
      end
      newest_install(cache_dir, relative_executable)
    end

    # Returns the directory that holds one subdirectory per Camoufox install,
    # as `platformdirs.user_cache_dir("camoufox")` in the Python package.
    def self.cache_dir(env : Hash(String, String) = ENV.to_h, home : Path = Path.home) : Path
      {% if flag?(:darwin) %}
        home / "Library/Caches/camoufox/browsers/official"
      {% else %}
        cache = env["XDG_CACHE_HOME"]?.presence.try { |dir| Path[dir] } || home / ".cache"
        cache / "camoufox/browsers/official"
      {% end %}
    end

    private def self.newest_install(cache_dir : Path, relative_executable : String) : String?
      return unless Dir.exists?(cache_dir)
      installs = Dir.children(cache_dir).compact_map do |name|
        install(cache_dir / name, relative_executable)
      end
      installs.max_by?(&.first).try(&.last)
    end

    # Returns the version and executable of the install in *directory*, or
    # `nil` when it has no valid `version.json` or no executable.
    private def self.install(directory : Path, relative_executable : String) : {SemanticVersion, String}?
      executable = (directory / relative_executable).to_s
      return unless File::Info.executable?(executable) && File.file?(executable)
      version = version_of(directory / "version.json")
      {version, executable} if version
    end

    # Parses `{"version": "152.0.4", "build": "beta.31"}` as the semantic
    # version `152.0.4-beta.31`, so build numbers compare numerically.
    private def self.version_of(path : Path) : SemanticVersion?
      return unless File.file?(path)
      info = VersionFile.from_json(File.read(path))
      # Pad "135.0" to "135.0.0"; SemanticVersion needs three parts.
      parts = info.version.split('.')
      version = (parts + ["0"] * {3 - parts.size, 0}.max).join('.')
      build = info.build.presence
      SemanticVersion.parse(build ? "#{version}-#{build}" : version)
    rescue JSON::ParseException | ArgumentError | IO::Error
      nil
    end

    private struct VersionFile
      include JSON::Serializable

      getter version : String
      getter build : String?
    end
  end
end
