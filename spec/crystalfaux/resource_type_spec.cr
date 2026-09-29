require "../spec_helper"

describe Crystalfaux::ResourceType do
  it "maps the Juggler cause, as Playwright does" do
    Crystalfaux::ResourceType.from_cause("TYPE_IMAGESET", "TYPE_IMAGESET").should eq(Crystalfaux::ResourceType::Image)
    Crystalfaux::ResourceType.from_cause("TYPE_SUBDOCUMENT", "TYPE_SUBDOCUMENT").should eq(Crystalfaux::ResourceType::Document)
    Crystalfaux::ResourceType.from_cause("TYPE_OTHER", "TYPE_INTERNAL_EVENTSOURCE").should eq(Crystalfaux::ResourceType::EventSource)
    Crystalfaux::ResourceType.from_cause("TYPE_UNKNOWN", "TYPE_UNKNOWN").should eq(Crystalfaux::ResourceType::Other)
  end
end
