require "../spec_helper"

private def glob_matches?(glob : String, url : String) : Bool
  Crystalfaux::URLGlob.to_regex(glob).matches?(url)
end

describe Crystalfaux::URLGlob do
  it "matches any characters but a slash with *, and anything with **" do
    glob_matches?("http://example.test/*.png", "http://example.test/a.png").should be_true
    glob_matches?("http://example.test/*.png", "http://example.test/img/a.png").should be_false
    glob_matches?("**/*.png", "http://example.test/img/a.png").should be_true
    glob_matches?("**/ads/**", "http://example.test/ads/x.js").should be_true
  end

  it "matches the whole URL and treats other characters literally" do
    glob_matches?("http://example.test/", "http://example.test/page").should be_false
    glob_matches?("http://example.test/a?b=1", "http://example.test/a?b=1").should be_true
    glob_matches?("http://example.test/a.b", "http://example.test/aXb").should be_false
  end
end
