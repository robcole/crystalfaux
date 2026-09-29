# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Portions of this file are translated to Crystal from Camoufox
# (https://github.com/daijro/camoufox, commit eb5dc3bc):
# - `pythonlib/camoufox/pkgman.py`
# - `pythonlib/camoufox/multiversion.py`
#
# Copyright the Camoufox authors. Like all Camoufox-derived files in
# crystalfaux, this file is under the MPL-2.0. See `NOTICE`.

require "json"
require "semantic_version"

module Crystalfaux::Fetch
  # A Camoufox build that a release offers for one platform: the version and
  # build from the asset name, and the asset to download.
  struct Build
    # The Firefox version, for example `"152.0.4"`.
    getter version : String
    # The Camoufox build, for example `"beta.31"`.
    getter build : String
    # The version and build as one `SemanticVersion`, for comparing builds.
    getter semantic_version : SemanticVersion
    # The release asset that holds the build.
    getter asset : Asset
    # Whether the build is a prerelease or an alpha build.
    getter? prerelease : Bool

    def initialize(@version : String, @build : String, @semantic_version : SemanticVersion,
                   @asset : Asset, @prerelease : Bool)
    end

    # Returns the build that *asset* holds for *platform*, or `nil` when the
    # asset is not a Camoufox archive for it. Alpha builds count as
    # prereleases, as in Camoufox `pythonlib/camoufox/pkgman.py`.
    def self.from(asset : Asset, release : Release, platform : Platform) : Build?
      version, build = platform.match(asset.name) || return
      semantic_version = Launcher::Discovery.semantic_version(version, build)
      new(version, build, semantic_version, asset, release.prerelease? || build.starts_with?("alpha"))
    rescue ArgumentError
      nil
    end

    # Returns `"<version>-<build>"`, for example `"152.0.4-beta.31"`.
    def name : String
      "#{version}-#{build}"
    end

    # Returns the SHA-256 of the asset in lowercase hex, or `nil` when the
    # release publishes none.
    def sha256 : String?
      asset.digest.try { |digest| digest.lchop?("sha256:").try(&.downcase) }
    end

    # Returns the name of the install directory: `<version>-<build>-<sha8>`,
    # or `<version>-<build>` without a digest (Camoufox
    # `pythonlib/camoufox/multiversion.py`, `version_folder_name`).
    def directory_name : String
      sha8 = sha256.try(&.[0, 8])
      sha8 ? "#{name}-#{sha8}" : name
    end

    # Returns the `version.json` for the install, with the keys of
    # `AvailableVersion.to_metadata` in Camoufox `pkgman.py`, so the Python
    # package and `Launcher::Discovery` both read it.
    def version_json : String
      {
        version:          version,
        build:            build,
        prerelease:       prerelease?,
        asset_id:         asset.id,
        asset_size:       asset.size,
        asset_updated_at: asset.updated_at,
        sha256:           sha256,
        created_at:       asset.created_at,
      }.to_json
    end

    # :nodoc:
    def sort_key : {SemanticVersion, String}
      {semantic_version, asset.created_at || ""}
    end
  end
end
