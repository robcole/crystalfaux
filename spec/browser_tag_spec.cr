require "./spec_helper"

describe "browser-tagged specs", tags: "browser" do
  it "receive the Camoufox binary named by CRYSTALFAUX_CAMOUFOX" do
    binary = camoufox_binary

    File::Info.executable?(binary).should be_true
  end
end
