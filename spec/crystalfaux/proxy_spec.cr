require "../spec_helper"

describe Crystalfaux::Proxy do
  it "does not show the password when inspected" do
    proxy = Crystalfaux::Proxy.new("proxy.test", 3128, username: "user", password: "secret")

    proxy.inspect.should_not contain("secret")
    proxy.to_s.should_not contain("secret")
    proxy.inspect.should contain("proxy.test:3128")
  end
end
