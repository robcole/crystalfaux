require "base64"
require "http/status"

module Crystalfaux
  # A network request of a page.
  #
  # A request that the browser intercepted waits until it is decided once:
  # `#abort`, `#continue` or `#fulfill`. `Page#on_request` handlers get
  # intercepted requests; the page continues a request that no handler
  # decides.
  #
  # ```
  # page.on_request do |request|
  #   if request.url.ends_with?("/api/user")
  #     request.fulfill(body: %({"name":"test"}), content_type: "application/json")
  #   elsif request.resource_type.image?
  #     request.abort
  #   end
  # end
  # ```
  class Request
    # The Juggler request id.
    getter id : String

    getter url : String

    # The HTTP method, for example `"GET"`.
    getter method : String

    getter headers : HTTP::Headers

    # The request body, decoded; `nil` when the request has none. Juggler
    # sends it base64-encoded (Camoufox
    # `additions/juggler/NetworkObserver.js`).
    getter post_data : Bytes?

    getter resource_type : ResourceType

    # The frame that sent the request; `nil` for a redirect.
    getter frame_id : String?

    # The page that sent the request.
    getter page : Page

    @navigation : Bool
    @intercepted : Bool
    @decided = Atomic(Bool).new(false)

    # :nodoc:
    def initialize(@page : Page, event : Protocol::Network::RequestWillBeSent)
      @id = event.request_id
      @url = event.url
      @method = event.method
      @headers = Protocol::Network::HTTPHeader.to_http(event.headers)
      @post_data = event.post_data.try { |encoded| Base64.decode(encoded) }
      @resource_type = ResourceType.from_cause(event.cause, event.internal_cause)
      @frame_id = event.frame_id
      @navigation = !event.navigation_id.nil?
      @intercepted = event.is_intercepted
    end

    # Whether the request loads a frame's document.
    def navigation? : Bool
      @navigation
    end

    # Whether the browser holds the request until it is decided.
    def intercepted? : Bool
      @intercepted
    end

    # Whether `#abort`, `#continue` or `#fulfill` was called.
    def decided? : Bool
      @decided.get
    end

    # Fails the request with *error_code*, one of the Juggler codes in
    # Camoufox `additions/juggler/NetworkObserver.js`, such as `"failed"`,
    # `"aborted"`, `"blockedbyclient"` or `"timedout"`. An unknown code
    # fails the request as `"failed"` does.
    def abort(error_code : String = "failed", timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      decide
      @page.call(Protocol::Network::AbortInterceptedRequest.new(@id, error_code), deadline(timeout))
    end

    # Sends the request on, with the given parts replaced. *post_data* is
    # the new body as the server receives it.
    def continue(*, url : String? = nil, method : String? = nil, headers : HTTP::Headers? = nil,
                 post_data : (String | Bytes)? = nil, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      decide
      request = Protocol::Network::ResumeInterceptedRequest.new(@id, url: url, method: method,
        headers: headers.try { |value| Protocol::Network::HTTPHeader.list(value) },
        post_data: post_data.try { |body| Base64.strict_encode(body) })
      @page.call(request, deadline(timeout))
    end

    # Answers the request without going to the network with *body*, as the
    # page receives it. Adds
    # `Content-Type` when *content_type* is given, and `Content-Length`
    # when *headers* have none.
    def fulfill(*, status : Int32 = 200, body : String | Bytes = "", headers : HTTP::Headers = HTTP::Headers.new,
                content_type : String? = nil, timeout : Time::Span = Browser::DEFAULT_TIMEOUT) : Nil
      decide
      headers = headers.dup
      headers["Content-Type"] = content_type if content_type
      headers["Content-Length"] = body.bytesize.to_s unless headers.has_key?("Content-Length")
      status_text = HTTP::Status.from_value?(status).try(&.description) || ""
      request = Protocol::Network::FulfillInterceptedRequest.new(@id, status, status_text,
        Protocol::Network::HTTPHeader.list(headers), Base64.strict_encode(body))
      @page.call(request, deadline(timeout))
    end

    # Marks the request decided, or raises when it cannot be.
    private def decide : Nil
      raise Error.new("Request #{@url} was not intercepted") unless @intercepted
      raise Error.new("Request #{@url} is already decided") if @decided.swap(true)
    end

    private def deadline(timeout : Time::Span) : Time::Instant
      Time.instant + timeout
    end
  end
end
