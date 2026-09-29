require "../../spec_helper"

private alias MainWorld = Crystalfaux::Protocol::Runtime::MainWorld

private def decode(json : String?) : JSON::Any
  MainWorld.decode(json.try { |text| JSON.parse(text) })
end

describe Crystalfaux::Protocol::Runtime::MainWorld do
  describe ".request" do
    it "has the call shape that Camoufox's Runtime.js recognizes as a main-world request" do
      request = MainWorld.request("id-3", "window.marker")

      JSON.parse(request.to_json).should eq(JSON.parse(<<-JSON))
        {
          "executionContextId": "id-3",
          "functionDeclaration": "(utilityScript, ...args) => utilityScript.evaluate(...args)",
          "returnByValue": true,
          "args": [{"value": null}, {"value": false}, {"value": true}, {"value": "mw:window.marker"}, {"value": 0}]
        }
        JSON
    end
  end

  describe ".decode" do
    it "passes plain JSON values through" do
      decode("42").should eq(JSON::Any.new(42_i64))
      decode(%("text")).should eq(JSON::Any.new("text"))
      decode("true").should eq(JSON::Any.new(true))
      # Playwright describes a DOM node as a string.
      decode(%("ref: <Node>")).should eq(JSON::Any.new("ref: <Node>"))
    end

    it "returns JSON null for undefined, null and a missing value" do
      decode(nil).should eq(JSON::Any.new(nil))
      decode(%({"v":"undefined"})).should eq(JSON::Any.new(nil))
      decode(%({"v":"null"})).should eq(JSON::Any.new(nil))
    end

    it "returns numbers that JSON cannot carry as floats" do
      decode(%({"v":"NaN"})).as_f.nan?.should be_true
      decode(%({"v":"Infinity"})).should eq(JSON::Any.new(Float64::INFINITY))
      decode(%({"v":"-Infinity"})).should eq(JSON::Any.new(-Float64::INFINITY))
      negative_zero = decode(%({"v":"-0"})).as_f
      negative_zero.should eq(0.0)
      negative_zero.sign_bit.should eq(-1)
    end

    it "decodes nested objects and arrays" do
      json = %({"o":[{"k":"a","v":{"o":[{"k":"b","v":{"a":[1,{"v":"undefined"},{"v":"null"}],"id":3}}],"id":2}}],"id":1})

      decode(json).should eq(JSON.parse(%({"a":{"b":[1,null,null]}})))
    end

    it "keeps an object property with no serialized value as nil" do
      # The browser's reply for ({a: 1, f: () => 1}): the function serializes
      # to undefined, so the entry has no "v".
      decode(%({"o":[{"k":"a","v":1},{"k":"f"}],"id":1})).should eq(JSON.parse(%({"a":1,"f":null})))
    end

    it "keeps special numbers nested in objects and arrays" do
      decoded = decode(%({"a":[{"v":"NaN"},{"v":"Infinity"},{"v":"-Infinity"},{"v":"-0"}],"id":1})).as_a.map(&.as_f)

      decoded[0].nan?.should be_true
      decoded[1..2].should eq([Float64::INFINITY, -Float64::INFINITY])
      decoded[3].sign_bit.should eq(-1)
    end

    it "returns a Date, a URL and a RegExp as strings" do
      decode(%({"d":"1970-01-01T00:00:00.000Z"})).should eq(JSON::Any.new("1970-01-01T00:00:00.000Z"))
      decode(%({"u":"https://example.com/"})).should eq(JSON::Any.new("https://example.com/"))
      decode(%({"r":{"p":"a+","f":"gi"}})).should eq(JSON::Any.new("/a+/gi"))
    end

    it "returns an Error as its name, message and stack" do
      decode(%({"e":{"n":"TypeError","m":"bad","s":"stack"}}))
        .should eq(JSON.parse(%({"name":"TypeError","message":"bad","stack":"stack"})))
    end

    it "repeats an object that the value references twice" do
      json = %({"a":[{"o":[{"k":"x","v":1}],"id":2},{"ref":2}],"id":1})

      decode(json).should eq(JSON.parse(%([{"x":1},{"x":1}])))
    end

    it "raises EvaluationError for values that JSON cannot carry" do
      expect_raises(Crystalfaux::EvaluationError, /cycle/) { decode(%({"o":[{"k":"a","v":{"ref":1}}],"id":1})) }
      expect_raises(Crystalfaux::EvaluationError, /BigInt/) { decode(%({"bi":"10"})) }
      expect_raises(Crystalfaux::EvaluationError, /not serializable/) { decode(%({"ta":{"b":"AA==","k":"ui8"}})) }
    end
  end
end
