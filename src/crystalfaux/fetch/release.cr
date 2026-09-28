require "json"

module Crystalfaux::Fetch
  # A GitHub release, with the fields of the releases API that `Fetch` uses.
  struct Release
    include JSON::Serializable

    getter? prerelease : Bool
    getter assets : Array(Asset)

    def initialize(@prerelease : Bool, @assets : Array(Asset))
    end
  end

  # A file attached to a GitHub release.
  struct Asset
    include JSON::Serializable

    getter id : Int64?
    getter name : String
    # The size in bytes.
    getter size : Int64
    # The checksum GitHub computes on upload, for example `"sha256:7b8d..."`.
    # Older releases have none.
    getter digest : String?
    getter browser_download_url : String
    getter created_at : String?
    getter updated_at : String?
  end
end
