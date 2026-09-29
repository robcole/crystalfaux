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

# Returns the Crystal compiler cache directory for this checkout and creates
# it when missing: `CRYSTAL_CACHE_DIR` when set, else `.crystal-cache` in the
# repository root. `bin/check` and `scripts/spec` export the same default.
#
# `crystal spec` and `crystal run` write their executable to one fixed name
# in the cache (`crystal-run-spec.tmp`), so two compiles that share a cache
# replace each other's executable. Keep one cache per checkout, and do not
# run two full compiles at once in one checkout.
#
# Every spec that starts a `crystal` child process must pass this directory
# explicitly. Inheriting the parent environment is not enough when the
# parent ran with the default cache.
#
# ```
# Process.run("crystal", ["build", "--no-codegen", fixture],
#   env: {"CRYSTAL_CACHE_DIR" => crystal_cache_dir})
# ```
def crystal_cache_dir : String
  dir = ENV["CRYSTAL_CACHE_DIR"]? || File.expand_path("../.crystal-cache", __DIR__)
  Dir.mkdir_p(dir)
  dir
end
