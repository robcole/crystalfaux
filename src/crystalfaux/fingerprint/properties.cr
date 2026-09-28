module Crystalfaux::Fingerprint
  # The config keys that Camoufox reads, and the type of each value, from
  # the vendored `data/camoufox/properties.json` (Camoufox
  # `settings/properties.json`).
  module Properties
    enum Type
      Str
      Int
      Uint
      Double
      Bool
      Array
      Dict

      # Whether *value* has this type, as `validate_type` in Camoufox
      # `pythonlib/camoufox/utils.py`, except that `true` and `false` are not
      # numbers here. An integer type accepts a float with no fraction,
      # because JSON does not tell them apart.
      def matches?(value : JSON::Any) : ::Bool
        raw = value.raw
        case self
        in .str?    then raw.is_a?(::String)
        in .int?    then integral?(raw)
        in .uint?   then integral?(raw) && non_negative?(raw)
        in .double? then raw.is_a?(Int64 | Float64)
        in .bool?   then raw.is_a?(::Bool)
        in .array?  then raw.is_a?(::Array)
        in .dict?   then raw.is_a?(::Hash)
        end
      end

      # The name of the type in `properties.json`, for example `"uint"`.
      def json_name : ::String
        to_s.downcase
      end

      private def integral?(raw) : ::Bool
        raw.is_a?(Int64) || (raw.is_a?(Float64) && raw.finite? && raw == raw.trunc)
      end

      private def non_negative?(raw) : ::Bool
        raw.is_a?(Int64 | Float64) && raw >= 0
      end
    end

    private struct Property
      include JSON::Serializable

      getter property : String
      getter type : String
    end

    # Every config key with its type.
    TYPES = Array(Property)
      .from_json({{ read_file("#{__DIR__}/../../../data/camoufox/properties.json") }})
      .to_h { |entry| {entry.property, Type.parse(entry.type)} }
  end
end
