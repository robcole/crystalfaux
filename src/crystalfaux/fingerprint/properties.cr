# Portions of this file are translated to Crystal from Camoufox
# (https://github.com/daijro/camoufox, commit eb5dc3bc):
# - `pythonlib/camoufox/utils.py`
#
# Copyright the Camoufox authors. `pythonlib/pyproject.toml` declares the
# Python package MIT; the repository root `LICENSE` is MPL-2.0. See
# `data/camoufox/README.md`.

module Crystalfaux::Fingerprint
  # The config keys that Camoufox reads, and the type of each value, from
  # the vendored `data/camoufox/properties.json` (Camoufox
  # `settings/properties.json`).
  module Properties
    # The value type of a config key, as `properties.json` names it.
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
      # numbers here. An integer type accepts a float with no fraction that
      # fits in an `Int64`; `#normalize` turns it into an integer.
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

      # Returns *value* in the form that Camoufox reads for this type: an
      # integer type turns a float with no fraction into an integer. Call it
      # on a value that `#matches?`.
      #
      # `MaskConfig.hpp` reads an integer key only when the JSON number is
      # an integer (`is_number_integer()`, `is_number_unsigned()`), so
      # `8.0` would be ignored and the host's real value would show. A
      # double key accepts integers, so it stays as given.
      def normalize(value : JSON::Any) : JSON::Any
        raw = value.raw
        return value unless (int? || uint?) && raw.is_a?(Float64)
        JSON::Any.new(raw.to_i64)
      end

      # The name of the type in `properties.json`, for example `"uint"`.
      def json_name : ::String
        to_s.downcase
      end

      private def integral?(raw) : ::Bool
        return true if raw.is_a?(Int64)
        raw.is_a?(Float64) && raw == raw.trunc && raw >= Int64::MIN.to_f && raw < Int64::MAX.to_f
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
