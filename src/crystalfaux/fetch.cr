require "semantic_version"

# Finds, downloads and installs Camoufox builds from GitHub releases, as
# `camoufox fetch` in Camoufox `pythonlib/camoufox/pkgman.py` does.
#
# `Client` reads the releases and downloads assets, `builds` and `select`
# choose a build for this platform, and `Installer` puts it into the cache
# directory that `Launcher::Discovery` searches.
#
# ```
# client = Crystalfaux::Fetch::Client.new
# build = Crystalfaux::Fetch.select(Crystalfaux::Fetch.builds(client.releases))
# Crystalfaux::Fetch::Installer.new(Crystalfaux::Launcher::Discovery.cache_dir, client).install(build)
# # => Path["/Users/me/Library/Caches/camoufox/browsers/official/152.0.4-beta.31-7b8d12d6"]
# ```
module Crystalfaux::Fetch
  # Returns the builds in *releases* for *platform*, newest first. Builds
  # of one version compare by asset creation time, newest first.
  def self.builds(releases : Array(Release), platform : Platform = Platform.current) : Array(Build)
    builds = releases.flat_map do |release|
      release.assets.compact_map { |asset| Build.from(asset, release, platform) }
    end
    builds.sort! { |left, right| right.sort_key <=> left.sort_key }
  end

  # Returns the build to install from *builds*, which are newest first.
  #
  # With *version*, returns the build whose name (`"152.0.4-beta.31"`) or
  # build (`"beta.31"`) matches. Without it, returns the newest build that
  # the vendored protocol supports. *allow_unsupported* lifts the
  # `Protocol::VENDORED` range.
  #
  # Raises `FetchError` when no build matches, and `UnsupportedBrowserError`
  # when the only matches are outside the supported range.
  def self.select(builds : Array(Build), version : String? = nil, allow_unsupported : Bool = false,
                  platform : Platform = Platform.current,
                  supported : Protocol::Vendored::BuildRange = Protocol::VENDORED.supported) : Build
    return select_version(builds, version, allow_unsupported, platform, supported) if version

    newest = builds.first?
    raise FetchError.new("No Camoufox build for #{platform}") unless newest
    return newest if allow_unsupported

    builds.find { |build| supported.includes?(build.semantic_version) } ||
      raise UnsupportedBrowserError.new(
        "No Camoufox build for #{platform} in the supported range #{supported}; the newest is #{newest.name}")
  end

  private def self.select_version(builds : Array(Build), version : String, allow_unsupported : Bool,
                                  platform : Platform, supported : Protocol::Vendored::BuildRange) : Build
    build = builds.find { |candidate| candidate.name == version || candidate.build == version }
    raise FetchError.new("No Camoufox build #{version} for #{platform}") unless build
    return build if allow_unsupported || supported.includes?(build.semantic_version)

    raise UnsupportedBrowserError.new(
      "Camoufox #{build.name} is not supported; crystalfaux speaks the protocol of #{supported}")
  end
end
