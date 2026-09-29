require "../../spec_helper"

private alias Client = Crystalfaux::Fetch::Client

private RELEASES = [{prerelease: false, assets: [] of String}].to_json

describe Crystalfaux::Fetch::Client do
  describe "#releases" do
    it "reads the releases of the first repository" do
      with_fake_github do |github|
        github.serve("/repos/daijro/camoufox/releases", RELEASES)

        releases = Client.new(api: github.uri, token: nil).releases
        releases.size.should eq(1)
        github.requests.should eq(["GET /repos/daijro/camoufox/releases"])
      end
    end

    it "falls back to the next repository when one fails" do
      with_fake_github do |github|
        github.serve("/repos/daijro/camoufox/releases", "rate limited", status: 403)
        github.serve("/repos/camoufox/camoufox/releases", RELEASES)

        Client.new(api: github.uri, token: nil).releases.size.should eq(1)
        github.requests.should eq(["GET /repos/daijro/camoufox/releases", "GET /repos/camoufox/camoufox/releases"])
      end
    end

    it "raises the last failure when every repository fails" do
      with_fake_github do |github|
        github.serve("/repos/daijro/camoufox/releases", "not json")

        expect_raises(Crystalfaux::FetchError, %r{camoufox/camoufox.*404}) do
          Client.new(api: github.uri, token: nil).releases
        end
      end
    end

    it "sends GITHUB_TOKEN as a bearer token to the API" do
      with_fake_github do |github|
        github.serve("/repos/daijro/camoufox/releases", RELEASES)

        Client.new(api: github.uri, token: "secret").releases
        github.authorizations.should eq(["Bearer secret"])
      end
    end
  end

  describe "#download" do
    it "follows redirects and reports progress" do
      with_fake_github do |github|
        github.redirect("/asset", to: github.url("/storage/asset"))
        github.serve("/storage/asset", "x" * 100)
        io = IO::Memory.new
        progress = [] of {Int64, Int64?}

        Client.new(api: github.uri, token: "secret").download(github.url("/asset"), io) do |received, total|
          progress << {received, total}
        end

        io.to_s.should eq("x" * 100)
        progress.last.should eq({100_i64, 100_i64})
      end
    end

    it "does not send the API token to download hosts" do
      with_fake_github do |github|
        github.serve("/asset", "x")
        Client.new(api: URI.parse("https://api.github.com"), token: "secret").download(github.url("/asset"), IO::Memory.new) { }
        github.authorizations.should eq([nil])
      end
    end

    it "raises on an error status" do
      with_fake_github do |github|
        expect_raises(Crystalfaux::FetchError, /404/) do
          Client.new(api: github.uri, token: nil).download(github.url("/missing"), IO::Memory.new) { }
        end
      end
    end

    it "stops after too many redirects" do
      with_fake_github do |github|
        github.redirect("/loop", to: "/loop")
        expect_raises(Crystalfaux::FetchError, /Too many redirects/) do
          Client.new(api: github.uri, token: nil).download(github.url("/loop"), IO::Memory.new) { }
        end
      end
    end
  end
end
