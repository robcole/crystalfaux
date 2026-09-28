require "http/client"
require "json"

module Crystalfaux::Fetch
  # Reads Camoufox releases from the GitHub API and downloads release
  # assets. Each request opens and closes its own connection.
  #
  # ```
  # client = Crystalfaux::Fetch::Client.new
  # client.releases.size # => 30
  # File.open("camoufox.zip", "w") do |file|
  #   client.download(url, file) { |received, total| }
  # end
  # ```
  class Client
    # The repositories to read releases from, in order: the primary and its
    # fallback (Camoufox `pythonlib/camoufox/repos.yml`, `Official`).
    REPOSITORIES = {"daijro/camoufox", "camoufox/camoufox"}

    MAX_REDIRECTS = 5

    # *api* is the GitHub API root. *token* is sent as a bearer token to the
    # API host only, never to the download host that assets redirect to.
    def initialize(@api : URI = URI.parse("https://api.github.com"),
                   @token : String? = ENV["GITHUB_TOKEN"]?.presence)
    end

    # Returns the releases of the first repository in *repositories* that
    # answers with a valid release list. Raises `FetchError` with the
    # failure of each repository when none does.
    def releases(repositories : Enumerable(String) = REPOSITORIES) : Array(Release)
      failures = [] of String
      repositories.each do |repository|
        uri = @api.resolve("/repos/#{repository}/releases?per_page=100")
        begin
          return get(uri) { |response| Array(Release).from_json(response.body_io) }
        rescue error : FetchError | JSON::ParseException
          failures << "#{repository}: #{error.message}"
        end
      end
      raise FetchError.new("Cannot read Camoufox releases (#{failures.join("; ")})")
    end

    # Writes the body of *url* to *io*, following redirects. Yields the bytes
    # received so far and the total from `Content-Length`, if the server
    # sends one, after each chunk. Raises `FetchError` on an error status or
    # a network failure.
    def download(url : String, io : IO, & : Int64, Int64? ->) : Nil
      get(URI.parse(url)) do |response|
        total = response.headers["Content-Length"]?.try(&.to_i64?)
        received = 0_i64
        buffer = Bytes.new(64 * 1024)
        while (count = response.body_io.read(buffer)) > 0
          io.write(buffer[0, count])
          received += count
          yield received, total
        end
      end
    end

    # Sends a GET to *uri*, follows up to `MAX_REDIRECTS` redirects, and
    # yields the first successful response.
    private def get(uri : URI, & : HTTP::Client::Response -> T) : T forall T
      (MAX_REDIRECTS + 1).times do
        location = nil
        connect(uri) do |client|
          client.get(uri.request_target, headers(uri)) do |response|
            location = response.headers["Location"]?.try { |target| uri.resolve(target) } if response.status.redirection?
            next if location
            raise FetchError.new("GET #{uri} failed: HTTP #{response.status_code}") unless response.success?
            return yield response
          end
        end
        uri = location if location
      end
      raise FetchError.new("Too many redirects from #{uri}")
    rescue error : IO::Error | OpenSSL::Error
      raise FetchError.new("GET #{uri} failed: #{error.message}")
    end

    private def connect(uri : URI, & : HTTP::Client ->) : Nil
      client = HTTP::Client.new(uri)
      client.connect_timeout = 30.seconds
      client.read_timeout = 60.seconds
      yield client
    ensure
      client.try &.close
    end

    private def headers(uri : URI) : HTTP::Headers
      headers = HTTP::Headers{"User-Agent" => "crystalfaux/#{VERSION}"}
      return headers unless uri.host == @api.host && uri.port == @api.port
      headers["Accept"] = "application/vnd.github+json"
      @token.try { |token| headers["Authorization"] = "Bearer #{token}" }
      headers
    end
  end
end
