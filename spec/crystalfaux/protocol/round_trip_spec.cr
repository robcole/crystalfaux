require "../../spec_helper"

private FRAMES = JugglerFrame.load(File.expand_path("../../fixtures/juggler/probe.frames", __DIR__))

describe "Juggler protocol round trip" do
  it "decodes and re-encodes every recorded frame without a difference" do
    round_trip = JugglerRoundTrip.new(FRAMES)

    round_trip.failures.should be_empty
    round_trip.unported_events.should be_empty
  end

  it "covers the probe's requests, results and events" do
    decoded = JugglerRoundTrip.new(FRAMES).decoded

    %w[
      Browser.enable Browser.getInfo Browser.createBrowserContext Browser.newPage Browser.close
      Browser.getCookies Browser.removeBrowserContext Page.navigate Page.setViewportSize
      Page.screenshot Page.dispatchMouseEvent Page.close Runtime.evaluate Runtime.callFunction
      Network.getResponseBody
    ].each { |method| decoded.should contain(method) }
    %w[
      Browser.getInfo Browser.newPage Browser.getCookies Page.navigate Page.screenshot
      Runtime.evaluate Runtime.callFunction Network.getResponseBody
    ].each { |method| decoded.should contain("#{method} result") }
    %w[
      Browser.attachedToTarget Browser.detachedFromTarget Page.frameAttached Page.eventFired
      Page.navigationStarted Page.navigationCommitted Page.ready Runtime.executionContextCreated
      Runtime.executionContextDestroyed Runtime.executionContextsCleared Network.requestWillBeSent
      Network.responseReceived Network.requestFinished
    ].each { |method| decoded.should contain(method) }
  end

  it "decodes and re-encodes the recorded element frames" do
    frames = JugglerFrame.load(File.expand_path("../../fixtures/juggler/elements.frames", __DIR__))
    round_trip = JugglerRoundTrip.new(frames)

    round_trip.failures.should be_empty
    %w[
      Runtime.getObjectProperties Runtime.disposeObject Page.scrollIntoViewIfNeeded Page.getContentQuads
      Page.adoptNode
    ].each do |method|
      round_trip.decoded.should contain(method)
      round_trip.decoded.should contain("#{method} result")
    end
  end

  it "reports a recorded field that a struct does not carry" do
    frames = [JugglerFrame.parse(%(< {"method":"Page.frameAttached","params":{"frameId":"f","extra":1}}))]

    JugglerRoundTrip.new(frames).failures.first.should contain("Page.frameAttached")
  end

  it "keeps the recorded null result apart from the undefined one" do
    results = FRAMES.select(&.text.includes?(%("result":{"result":{))).map do |frame|
      Crystalfaux::Protocol.decode(Crystalfaux::Protocol::Runtime::EvaluationResult, frame.json["result"]).result
    end
    values = results.map(&.try(&.value))

    values.should contain(JSON::Any.new(nil))
    values.count(&.nil?).should be > 0
  end

  it "decodes recorded events into typed values" do
    attached = FRAMES.find!(&.text.includes?(%("Browser.attachedToTarget"))).json["params"]
    event = Crystalfaux::Protocol.decode(Crystalfaux::Protocol::Browser::AttachedToTarget, attached)
    event.target_info.type.should eq(Crystalfaux::Protocol::Browser::TargetType::Page)

    cookie = FRAMES.find!(&.text.includes?(%("cookies":[))).json["result"]["cookies"][0]
    Crystalfaux::Protocol.decode(Crystalfaux::Protocol::Browser::Cookie, cookie).same_site
      .should eq(Crystalfaux::Protocol::Browser::SameSite::None)
  end
end
