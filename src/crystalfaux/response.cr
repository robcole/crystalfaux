require "base64"

module Crystalfaux
  # The response to a `Request`, as `Page#on_response` passes it.
  #
  # ```
  # page.on_response do |response|
  #   puts response.text if response.url.ends_with?("/api/user")
  # end
  # ```
  #
  # The body is complete only after the request finishes. `#body` waits for
  # that, then reads the body from the browser. The page tells the response
  # that the request finished or failed, or that the page closed or
  # crashed; see `Page::Traffic`.
  class Response
    # The request that this response answers.
    getter request : Request

    # The HTTP status code, for example `200`.
    getter status : Int32

    # The HTTP status text, for example `"OK"`.
    getter status_text : String

    # The response headers.
    getter headers : HTTP::Headers

    # The IP address of the server, when the browser knows it.
    getter remote_ip_address : String?

    # The port of the server, when the browser knows it.
    getter remote_port : Int32?

    @from_cache : Bool
    @lock = Sync::Mutex.new
    # Closed when the request finishes, fails or is abandoned.
    @done = Channel(Nil).new
    @failure : Exception?

    # :nodoc:
    def initialize(@request : Request, event : Protocol::Network::ResponseReceived)
      @status = event.status
      @status_text = event.status_text
      @headers = Protocol::Network::HTTPHeader.to_http(event.headers)
      @remote_ip_address = event.remote_ip_address
      @remote_port = event.remote_port
      @from_cache = event.from_cache
    end

    # The URL of the request.
    def url : String
      @request.url
    end

    # Whether the browser took the response from its cache.
    def from_cache? : Bool
      @from_cache
    end

    # The body, decoded as the browser received it (without its transfer
    # encoding).
    #
    # Waits for the request to finish. Raises `TimeoutError` when it does
    # not finish, or the browser does not send the body, within *timeout*;
    # `Error` when the request failed or the browser dropped the body from
    # its storage; and `PageClosed`, `PageCrashed` or `ConnectionClosed`
    # when the page goes away first.
    def body(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Bytes
      deadline = Time.instant + timeout
      wait_until_done(timeout)
      result = @request.page.call(Protocol::Network::GetResponseBody.new(@request.id), deadline)
      if result.evicted
        raise Error.new("Response body for #{@request.method} #{url} was evicted")
      end
      Base64.decode(result.base64body)
    end

    # The body as a UTF-8 string. See `#body`.
    def text(timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : String
      String.new(body(timeout))
    end

    # Ends the wait of `#body`: with *failure* it raises that, without it
    # reads the body. Only the first call counts.
    protected def finish(failure : Exception? = nil) : Nil
      @lock.synchronize do
        return if @done.closed?
        @failure = failure
        @done.close
      end
    end

    private def wait_until_done(timeout : Time::Span) : Nil
      select
      when @done.receive?
      when timeout(timeout)
        raise TimeoutError.new("Response for #{url} did not finish within #{timeout}")
      end
      failure = @lock.synchronize { @failure }
      raise failure if failure
    end
  end
end
