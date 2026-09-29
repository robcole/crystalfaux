require "compress/zip"
require "digest/sha256"
require "http/server"

# A loopback HTTP server that stands in for the GitHub releases API and its
# download host. Each route answers with a fixed status, body and headers.
#
# ```
# with_fake_github do |github|
#   github.serve("/repos/daijro/camoufox/releases", "[]")
#   client = Crystalfaux::Fetch::Client.new(api: github.uri)
# end
# ```
class FakeGitHub
  # *sent* is the number of body bytes to write before the connection
  # drops; `nil` writes the whole body.
  private record Route, status : Int32, body : Bytes, headers : HTTP::Headers, sent : Int32? = nil

  # The request lines received so far, for example `"GET /x"`.
  getter requests = [] of String

  # The `Authorization` header of each request, in order.
  getter authorizations = [] of String?

  def initialize
    @routes = {} of String => Route
    @server = HTTP::Server.new { |context| handle(context) }
    @address = @server.bind_tcp("127.0.0.1", 0)
    spawn { @server.listen }
    # Let the server start listening, so an early `close` does not race it.
    Fiber.yield
  end

  def uri : URI
    URI.parse("http://127.0.0.1:#{@address.port}")
  end

  def url(path : String) : String
    "#{uri}#{path}"
  end

  def serve(path : String, body : String | Bytes, status : Int32 = 200) : Nil
    @routes[path] = Route.new(status, body.to_slice, HTTP::Headers.new)
  end

  # Serves *body* with its full `Content-Length`, but closes the connection
  # after *sent* bytes.
  def truncate(path : String, body : Bytes, sent : Int32) : Nil
    @routes[path] = Route.new(200, body, HTTP::Headers.new, sent)
  end

  def redirect(path : String, to location : String) : Nil
    @routes[path] = Route.new(302, Bytes.empty, HTTP::Headers{"Location" => location})
  end

  def close : Nil
    @server.close
  end

  private def handle(context : HTTP::Server::Context) : Nil
    request = context.request
    @requests << "#{request.method} #{request.path}"
    @authorizations << request.headers["Authorization"]?
    route = @routes[request.path]? || Route.new(404, "not found".to_slice, HTTP::Headers.new)
    context.response.status_code = route.status
    context.response.headers.merge!(route.headers)
    context.response.content_length = route.body.size
    if sent = route.sent
      context.response.upgrade do |io|
        io.write(route.body[0, sent])
        io.close
      end
    else
      context.response.write(route.body)
    end
  end
end

def with_fake_github(&)
  github = FakeGitHub.new
  yield github
ensure
  github.try &.close
end

# Returns a zip archive that holds *files*, keyed by path inside the archive.
def zip_archive(files : Hash(String, String)) : Bytes
  io = IO::Memory.new
  Compress::Zip::Writer.open(io) do |zip|
    files.each { |name, content| zip.add(name, content) }
  end
  io.to_slice
end

# Returns one GitHub release asset as the releases API describes it.
def release_asset(name : String, url : String, body : Bytes, digest : Bool = true)
  {
    "id"                   => 1,
    "name"                 => name,
    "size"                 => body.size,
    "digest"               => digest ? "sha256:#{Digest::SHA256.hexdigest(body)}" : nil,
    "browser_download_url" => url,
    "created_at"           => "2026-09-24T21:57:25Z",
    "updated_at"           => "2026-09-24T21:57:25Z",
  }
end
