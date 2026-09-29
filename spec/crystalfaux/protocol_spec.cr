require "../spec_helper"

private alias Protocol = Crystalfaux::Protocol

describe Crystalfaux::Protocol do
  describe ".call" do
    it "sends the request's method and params and decodes the result" do
      connection, peer = connected_pair
      reply = Channel(Protocol::Page::Navigate::Result | Exception).new(1)
      spawn do
        reply.send(Protocol.call(connection, Protocol::Page::Navigate.new("frame-1", "https://example.com/"), "session-1"))
      rescue ex
        reply.send(ex)
      end

      request = peer.request
      request["method"].should eq("Page.navigate")
      request["params"].should eq(JSON.parse(%({"frameId":"frame-1","url":"https://example.com/"})))
      request["sessionId"].should eq("session-1")
      peer.reply(request["id"], {navigationId: "nav-1"}, "session-1")

      result = receive_within(reply).should be_a(Protocol::Page::Navigate::Result)
      result.navigation_id.should eq("nav-1")
    ensure
      connection.try &.close
    end

    it "decodes a reply without a result as an empty result" do
      connection, peer = connected_pair
      reply = Channel(Protocol::Empty | Exception).new(1)
      spawn do
        reply.send(Protocol.call(connection, Protocol::Browser::Enable.new(false)))
      rescue ex
        reply.send(ex)
      end

      request = peer.request
      request["params"].should eq(JSON.parse(%({"attachToDefaultContext":false})))
      peer.raw(%({"id":#{request["id"]}}))

      receive_within(reply).should be_a(Protocol::Empty)
    ensure
      connection.try &.close
    end

    it "raises when a reply without a result is not for an empty result" do
      connection, peer = connected_pair
      reply = Channel(Protocol::Runtime::EvaluationResult | Exception).new(1)
      spawn do
        reply.send(Protocol.call(connection, Protocol::Runtime::Evaluate.new("id-1", "1"), "session-1"))
      rescue ex
        reply.send(ex)
      end

      peer.raw(%({"id":#{peer.request["id"]},"sessionId":"session-1"}))

      error = receive_within(reply).should be_a(Crystalfaux::ProtocolError)
      error.message.should eq("Protocol error (Runtime.evaluate): the reply has no result")
    ensure
      connection.try &.close
    end

    it "raises when the result does not match the schema" do
      connection, peer = connected_pair
      reply = Channel(Protocol::Browser::GetInfo::Result | Exception).new(1)
      spawn do
        reply.send(Protocol.call(connection, Protocol::Browser::GetInfo.new))
      rescue ex
        reply.send(ex)
      end

      peer.reply(peer.request["id"], {version: "Firefox/152.0.4-beta.31"})

      receive_within(reply).should be_a(JSON::SerializableError)
    ensure
      connection.try &.close
    end
  end

  describe "field encoding" do
    it "leaves out optional fields that are nil and writes nullable ones as null" do
      Protocol::Browser::NewPage.new.to_json.should eq("{}")
      Protocol::Page::SetViewportSize.new(nil).to_json.should eq(%({"viewportSize":null}))
      Protocol::Network::FulfillInterceptedRequest.new("r1", 200, "OK", [] of Protocol::Network::HTTPHeader, "aGk=").to_json
        .should eq(%({"requestId":"r1","status":200,"statusText":"OK","headers":[],"base64body":"aGk="}))
    end

    it "writes enum values as the protocol spells them" do
      clip = Protocol::Page::Clip.new(0, 0, 10, 10)
      JSON.parse(Protocol::Page::Screenshot.new(:jpeg, clip, quality: 80).to_json)["mimeType"].should eq("image/jpeg")
      Protocol::Page::LifecycleEvent::DomContentLoaded.to_json.should eq(%("DOMContentLoaded"))
      Protocol::Runtime::UnserializableValue::NegativeZero.to_json.should eq(%("-0"))
    end

    it "keeps an explicit null runtime value apart from an absent one" do
      {% for type in [Protocol::Runtime::RemoteObject, Protocol::Runtime::ExceptionDetails, Protocol::Runtime::CallFunctionArgument] %}
        explicit = {{ type }}.from_json(%({"value":null}))
        explicit.value.should eq(JSON::Any.new(nil))
        explicit.to_json.should eq(%({"value":null}))

        absent = {{ type }}.from_json("{}")
        absent.value.should be_nil
        absent.to_json.should eq("{}")
      {% end %}
      Protocol::Runtime::CallFunctionArgument.new(value: JSON::Any.new(nil)).to_json.should eq(%({"value":null}))
      Protocol::Runtime::CallFunctionArgument.new(object_id: "o1").to_json.should eq(%({"objectId":"o1"}))
    end

    it "rejects an enum value the schema does not list" do
      expect_raises(JSON::SerializableError, /Unknown LifecycleEvent "unload"/) do
        Protocol::Page::EventFired.from_json(%({"frameId":"f","name":"unload"}))
      end
    end
  end

  describe "Network::HTTPHeader.to_http" do
    it "splits the newline-joined values of a repeated response header" do
      params = JSON.parse(<<-'JSON')
        {"securityDetails":null,"requestId":"r1","fromCache":false,"status":200,"statusText":"OK",
         "headers":[{"name":"Content-Type","value":"text/html"},{"name":"Set-Cookie","value":"a=1; Path=/\nb=2; Path=/"}],
         "timing":{"startTime":0,"domainLookupStart":0,"domainLookupEnd":0,"connectStart":0,
                   "secureConnectionStart":0,"connectEnd":0,"requestStart":0,"responseStart":0},
         "fromServiceWorker":false}
        JSON
      event = Protocol.decode(Protocol::Network::ResponseReceived, params)

      headers = Protocol::Network::HTTPHeader.to_http(event.headers)

      headers.get("Set-Cookie").should eq(["a=1; Path=/", "b=2; Path=/"])
      headers.get("Content-Type").should eq(["text/html"])
    end
  end
end
