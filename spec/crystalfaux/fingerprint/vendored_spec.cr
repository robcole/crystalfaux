require "../../spec_helper"
require "digest/sha256"

private DATA_DIR = File.expand_path("../../../data/camoufox", __DIR__)

private struct VendoredFile
  include JSON::Serializable

  getter source : String
  getter sha256 : String
end

private struct VendoredData
  include JSON::Serializable

  getter commit : String
  getter files : Hash(String, VendoredFile)
end

describe "vendored Camoufox data" do
  it "records the checksum of each file and comes from the commit of Protocol.js" do
    record = VendoredData.from_json(File.read(File.join(DATA_DIR, "VERSION.json")))

    record.commit.should eq(Crystalfaux::Protocol::VENDORED.commit)
    record.files.keys.sort!.should eq(["fonts.json", "properties.json"])
    record.files.each do |name, file|
      Digest::SHA256.hexdigest(File.read(File.join(DATA_DIR, name))).should eq(file.sha256)
      file.source.should contain(record.commit)
    end
  end

  it "knows every property of properties.json" do
    properties = JSON.parse(File.read(File.join(DATA_DIR, "properties.json"))).as_a

    Crystalfaux::Fingerprint::Properties::TYPES.size.should eq(properties.size)
    Crystalfaux::Fingerprint::Properties::TYPES["screen.width"].should eq(Crystalfaux::Fingerprint::Properties::Type::Uint)
  end
end
