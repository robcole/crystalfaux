require "./spec_helper"
require "file_utils"

private def with_cache_env(value : String?, &)
  previous = ENV["CRYSTAL_CACHE_DIR"]?
  if value
    ENV["CRYSTAL_CACHE_DIR"] = value
  else
    ENV.delete("CRYSTAL_CACHE_DIR")
  end
  yield
ensure
  if previous
    ENV["CRYSTAL_CACHE_DIR"] = previous
  else
    ENV.delete("CRYSTAL_CACHE_DIR")
  end
end

describe "crystal_cache_dir" do
  it "uses CRYSTAL_CACHE_DIR and creates the directory" do
    root = File.tempname("crystalfaux-cache")
    dir = File.join(root, "nested")
    begin
      with_cache_env(dir) do
        crystal_cache_dir.should eq(dir)
        Dir.exists?(dir).should be_true
      end
    ensure
      FileUtils.rm_rf(root)
    end
  end

  it "falls back to .crystal-cache in the checkout" do
    with_cache_env(nil) do
      dir = crystal_cache_dir

      dir.should eq(File.expand_path("../.crystal-cache", __DIR__))
      Dir.exists?(dir).should be_true
    end
  end
end
