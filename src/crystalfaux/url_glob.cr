module Crystalfaux
  # :nodoc:
  #
  # Turns a URL glob into a `Regex` that matches the whole URL: `**` matches
  # any characters, `*` any characters except `/`, and every other character
  # matches itself.
  #
  # ```
  # URLGlob.to_regex("**/*.png").matches?("https://example.com/img/a.png") # => true
  # ```
  module URLGlob
    def self.to_regex(glob : String) : Regex
      pattern = glob.split("**").join(".*") { |part| part.split('*').join("[^/]*") { |text| Regex.escape(text) } }
      Regex.new("\\A#{pattern}\\z")
    end
  end
end
