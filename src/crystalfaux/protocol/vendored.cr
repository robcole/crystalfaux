require "semantic_version"

module Crystalfaux::Protocol
  # The record of the vendored `protocol/Protocol.js`, read from
  # `protocol/VERSION.json` at compile time.
  struct Vendored
    include JSON::Serializable

    # The Camoufox commit the file came from.
    getter commit : String

    # The Camoufox version and build the file came from, for example
    # `"152.0.4"` and `"beta.31"`.
    getter camoufox_version : String
    getter camoufox_build : String

    # The SHA-256 of `protocol/Protocol.js`, in lowercase hex.
    getter sha256 : String

    # The Camoufox builds that use this protocol, inclusive.
    getter supported : BuildRange

    # Whether a Camoufox install of *version* speaks the vendored protocol.
    def supports?(version : SemanticVersion) : Bool
      supported.includes?(version)
    end

    # The inclusive range of supported builds.
    struct BuildRange
      include JSON::Serializable

      @[JSON::Field(converter: Crystalfaux::Protocol::Vendored::VersionConverter)]
      getter min : SemanticVersion
      @[JSON::Field(converter: Crystalfaux::Protocol::Vendored::VersionConverter)]
      getter max : SemanticVersion

      def includes?(version : SemanticVersion) : Bool
        min <= version && version <= max
      end

      def to_s(io : IO) : Nil
        io << min << " to " << max
      end
    end

    # :nodoc:
    module VersionConverter
      def self.from_json(pull : JSON::PullParser) : SemanticVersion
        SemanticVersion.parse(pull.read_string)
      end

      def self.to_json(value : SemanticVersion, json : JSON::Builder) : Nil
        json.string(value.to_s)
      end
    end
  end

  VENDORED = Vendored.from_json({{ read_file("#{__DIR__}/../../../protocol/VERSION.json") }})

  # Checks that the Camoufox install in *install_dir* speaks the vendored
  # protocol, and returns its version.
  #
  # *install_dir* is the directory that holds `version.json`, not the
  # directory of the executable (see `Launcher::Discovery`). Raises
  # `UnsupportedBrowserError` when `version.json` is missing or not valid, or
  # when the version is outside `VENDORED.supported`.
  #
  # ```
  # Crystalfaux::Protocol.check_install("#{cache}/152.0.4-beta.31-7b8d12d6")
  # # => SemanticVersion(@major=152, @minor=0, @patch=4, @prerelease=beta.31)
  # ```
  def self.check_install(install_dir : String | Path) : SemanticVersion
    directory = Path[install_dir]
    version = Launcher::Discovery.install_version(directory)
    unless version
      raise UnsupportedBrowserError.new("No valid version.json in #{directory}")
    end
    unless VENDORED.supports?(version)
      raise UnsupportedBrowserError.new(
        "Camoufox #{version} in #{directory} is not supported; crystalfaux speaks the protocol of #{VENDORED.supported}")
    end
    version
  end
end
