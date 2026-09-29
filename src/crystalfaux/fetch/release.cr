require "json"

module Crystalfaux::Fetch
  # A GitHub release, with the fields of the releases API that `Fetch` uses.
  struct Release
    include JSON::Serializable

    # Whether GitHub marks the release as a prerelease.
    getter? prerelease : Bool
    # The files attached to the release.
    getter assets : Array(Asset)

    def initialize(@prerelease : Bool, @assets : Array(Asset))
    end
  end

  # A file attached to a GitHub release.
  struct Asset
    include JSON::Serializable

    # The GitHub asset id.
    getter id : Int64?
    # The file name, for example `"camoufox-152.0.4-beta.31-mac.arm64.zip"`.
    getter name : String
    # The size in bytes.
    getter size : Int64
    # The checksum GitHub computes on upload, for example `"sha256:7b8d..."`.
    # Older releases have none.
    getter digest : String?
    # The URL to download the file from.
    getter browser_download_url : String
    # When the file was uploaded, as an ISO 8601 time.
    getter created_at : String?
    # When the file last changed, as an ISO 8601 time.
    getter updated_at : String?
  end
end
