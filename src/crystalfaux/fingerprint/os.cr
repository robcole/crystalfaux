# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Portions of this file are translated to Crystal from Camoufox
# (https://github.com/daijro/camoufox, commit eb5dc3bc):
# - `pythonlib/camoufox/fingerprints.py`
#
# Copyright the Camoufox authors. Like all Camoufox-derived files in
# crystalfaux, this file is under the MPL-2.0. See `NOTICE`.

module Crystalfaux::Fingerprint
  # Fonts of each OS, keyed `mac`, `win` and `lin`, from the vendored
  # `data/camoufox/fonts.json` (Camoufox `pythonlib/camoufox/fonts.json`).
  private FONTS = Hash(String, Array(String))
    .from_json({{ read_file("#{__DIR__}/../../../data/camoufox/fonts.json") }})

  # The operating system that a fingerprint claims.
  enum OS
    Mac
    Windows
    Linux

    # Returns the OS that *user_agent* names, or raises `ConfigError`.
    #
    # ```
    # OS.from_user_agent("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:152.0) Gecko/20100101 Firefox/152.0")
    # # => Crystalfaux::Fingerprint::OS::Windows
    # ```
    def self.from_user_agent(user_agent : String) : self
      tokens = platform_tokens(user_agent)
      return Windows if tokens.any?(&.starts_with?("Windows"))
      return Mac if tokens.any? { |token| token == "Macintosh" || token.includes?("Mac OS X") }
      return Linux if tokens.any? { |token| token == "X11" || token.starts_with?("Linux") }
      raise ConfigError.new("Cannot tell the OS of the user agent #{user_agent.inspect}")
    end

    # The parts of the parenthesised platform block of *user_agent*, for
    # example `["Macintosh", "Intel Mac OS X 10.15", "rv:152.0"]`.
    def self.platform_tokens(user_agent : String) : Array(String)
      block = user_agent.match(/\AMozilla\/5\.0 \(([^)]*)\)/).try(&.[1])
      return [] of String unless block
      block.split(';').map(&.strip)
    end

    # The value of `navigator.platform` for *user_agent*. Linux takes the
    # architecture from the user agent, as `fix_navigator_arch` in Camoufox
    # `pythonlib/camoufox/fingerprints.py`.
    def platform(user_agent : String) : String
      case self
      in .mac?     then "MacIntel"
      in .windows? then "Win32"
      in .linux?   then linux_arch(user_agent)
      end
    end

    # The value of `navigator.oscpu` for *user_agent*: the OS tokens of the
    # user agent, as Firefox builds it.
    def oscpu(user_agent : String) : String
      tokens = OS.platform_tokens(user_agent).reject(&.starts_with?("rv:"))
      case self
      in .mac?
        tokens.find(&.starts_with?("Intel Mac OS X")) || "Intel Mac OS X 10.15"
      in .windows?
        start = tokens.index(&.starts_with?("Windows NT"))
        start ? tokens[start..].join("; ") : "Windows NT 10.0; Win64; x64"
      in .linux?
        linux_arch(user_agent)
      end
    end

    # The height in pixels that the OS keeps for its menu bar or taskbar
    # (`fix_screen_no_taskbar` in Camoufox `pythonlib/camoufox/fingerprints.py`).
    def taskbar_height : Int32
      case self
      in .mac?     then 25
      in .windows? then 40
      in .linux?   then 27
      end
    end

    # Every font family of the OS.
    def fonts : Array(String)
      key = case self
            in .mac?     then "mac"
            in .windows? then "win"
            in .linux?   then "lin"
            end
      FONTS[key].dup
    end

    private def linux_arch(user_agent : String) : String
      OS.platform_tokens(user_agent).find(&.starts_with?("Linux ")) || "Linux x86_64"
    end
  end
end
