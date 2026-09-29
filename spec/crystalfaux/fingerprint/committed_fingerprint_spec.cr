require "../../spec_helper"

private DIR = Path[__DIR__, "..", "..", "..", "examples", "fingerprints"].normalize

describe "the committed macOS desktop fingerprint" do
  it "is a config that Fingerprint::Config accepts" do
    config = Crystalfaux::Fingerprint::Config.from_json(File.read(DIR / "macos-desktop.json"))

    user_agent = config["navigator.userAgent"].as_s
    Crystalfaux::Fingerprint::OS.from_user_agent(user_agent).should eq(Crystalfaux::Fingerprint::OS::Mac)
    config["navigator.platform"].should eq(JSON::Any.new("MacIntel"))
    config["screen.availHeight"].as_i.should be <= config["screen.height"].as_i
  end

  it "has prefs that Browser.launch accepts" do
    prefs = JSON.parse(File.read(DIR / "macos-desktop.prefs.json")).as_h

    prefs.should_not be_empty
    Crystalfaux::Launcher.check_prefs(prefs)
  end
end
