module Crystalfaux::Fetch
  # An operating system and architecture, named as in Camoufox release
  # assets: `os` is `"mac"` or `"lin"`, `arch` is `"x86_64"`, `"arm64"` or
  # `"i686"` (Camoufox `pythonlib/camoufox/pkgman.py`, `OS_MAP` and
  # `ARCH_MAP`).
  #
  # ```
  # Platform.new("mac", "arm64").match("camoufox-152.0.4-beta.31-mac.arm64.zip")
  # # => {"152.0.4", "beta.31"}
  # ```
  record Platform, os : String, arch : String do
    # Returns the platform this program was compiled for.
    def self.current : Platform
      new(
        {{ flag?(:darwin) ? "mac" : "lin" }},
        {{ flag?(:aarch64) ? "arm64" : flag?(:x86_64) ? "x86_64" : "i686" }},
      )
    end

    # Returns the version and build of *asset_name* when it is a Camoufox
    # archive for this platform, or `nil` otherwise.
    #
    # The asset pattern is `{name}-{version}-{build}-{os}.{arch}.zip`
    # (Camoufox `pythonlib/camoufox/repos.yml`).
    def match(asset_name : String) : {String, String}?
      pattern = /\A\w+-(?<version>[^-]+)-(?<build>[^-]+)-#{Regex.escape(os)}\.#{Regex.escape(arch)}\.zip\z/
      match = pattern.match(asset_name)
      {match["version"], match["build"]} if match
    end

    def to_s(io : IO) : Nil
      io << os << ' ' << arch
    end
  end
end
