require "spec"
require "../src/crystalfaux"
require "./support/*"

# Specs that need a real Camoufox browser follow this convention:
#
# - Tag the example group or example with `browser`.
# - Get the binary path from `camoufox_binary` at the start of each example.
#
# `camoufox_binary` marks the example pending when `CRYSTALFAUX_CAMOUFOX`
# does not name an executable file, so the default `crystal spec` run stays
# offline and hermetic. To run only the browser specs:
#
# ```sh
# CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal spec --tag browser
# ```
#
# Example:
#
# ```
# describe Crystalfaux::Browser, tags: "browser" do
#   it "opens a page" do
#     binary = camoufox_binary
#     # launch the browser with `binary`
#   end
# end
# ```
def camoufox_binary : String
  path = ENV["CRYSTALFAUX_CAMOUFOX"]?
  unless path && File.file?(path) && File::Info.executable?(path)
    pending!("set CRYSTALFAUX_CAMOUFOX to a Camoufox binary to run browser specs")
  end
  path
end
