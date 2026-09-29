module Crystalfaux::Protocol
  # The `Network` domain: per-page request interception and request
  # lifecycle events. The structs sit in one file because each is a small
  # value type of the same schema section.
  module Network
    # The `HTTPHeader` type of the Juggler schema.
    struct HTTPHeader
      include Message

      field name : String
      field value : String

      def initialize(@name : String, @value : String)
      end

      # One header per value of *headers*, in order.
      def self.list(headers : HTTP::Headers) : Array(HTTPHeader)
        headers.flat_map { |name, values| values.map { |value| new(name, value) } }
      end

      # *headers* as `HTTP::Headers`; a repeated name keeps every value.
      #
      # Firefox merges repeated response headers such as `Set-Cookie` into
      # one entry, joined with a newline, and Juggler forwards that entry
      # unchanged (Camoufox `additions/juggler/NetworkObserver.js:960`,
      # `responseHead`). Juggler splits `Set-Cookie` on `'\n'` itself when
      # it fulfills a request (`NetworkObserver.js:208`). A newline is never
      # valid in a header value, so every value is split on it.
      def self.to_http(headers : Array(HTTPHeader)) : HTTP::Headers
        headers.each_with_object(HTTP::Headers.new) do |header, http|
          header.value.split('\n') { |value| http.add(header.name, value) }
        end
      end
    end

    # The `SecurityDetails` type of the Juggler schema.
    struct SecurityDetails
      include Message

      field protocol : String
      field subject_name : String
      field issuer : String
      field valid_from : Float64
      field valid_to : Float64
    end

    # Absolute timestamps in microseconds since the epoch, as
    # `nsITimedChannel` reports them; `0` when a phase did not run, for
    # example DNS and connect on a reused connection (Camoufox
    # `additions/juggler/NetworkObserver.js` forwards them unchanged).
    struct ResourceTiming
      include Message

      field start_time : Float64
      field domain_lookup_start : Float64
      field domain_lookup_end : Float64
      field connect_start : Float64
      field secure_connection_start : Float64
      field connect_end : Float64
      field request_start : Float64
      field response_start : Float64
    end

    # The `Network.setRequestInterception` request.
    struct SetRequestInterception
      include Message
      include Request(Empty)
      METHOD = "Network.setRequestInterception"

      field enabled : Bool

      def initialize(@enabled : Bool)
      end
    end

    # The `Network.setExtraHTTPHeaders` request.
    struct SetExtraHTTPHeaders
      include Message
      include Request(Empty)
      METHOD = "Network.setExtraHTTPHeaders"

      field headers : Array(HTTPHeader)

      def initialize(@headers : Array(HTTPHeader))
      end
    end

    # Fails an intercepted request. *error_code* is a Playwright error code
    # such as `"aborted"` or `"failed"`.
    struct AbortInterceptedRequest
      include Message
      include Request(Empty)
      METHOD = "Network.abortInterceptedRequest"

      field request_id : String
      field error_code : String

      def initialize(@request_id : String, @error_code : String)
      end
    end

    # Lets an intercepted request continue, with optional overrides.
    struct ResumeInterceptedRequest
      include Message
      include Request(Empty)
      METHOD = "Network.resumeInterceptedRequest"

      field request_id : String
      field url : String?
      field method : String?
      field headers : Array(HTTPHeader)?
      # Base64-encoded.
      field post_data : String?

      def initialize(@request_id : String, *, @url : String? = nil, @method : String? = nil,
                     @headers : Array(HTTPHeader)? = nil, @post_data : String? = nil)
      end
    end

    # Answers an intercepted request without going to the network.
    struct FulfillInterceptedRequest
      include Message
      include Request(Empty)
      METHOD = "Network.fulfillInterceptedRequest"

      field request_id : String
      field status : Int32
      field status_text : String
      field headers : Array(HTTPHeader)
      field base64body : String?, key: "base64body"

      def initialize(@request_id : String, @status : Int32, @status_text : String,
                     @headers : Array(HTTPHeader), @base64body : String? = nil)
      end
    end

    # The `Network.getResponseBody` request.
    struct GetResponseBody
      include Message

      # The result of `Network.getResponseBody`.
      struct Result
        include Message

        field base64body : String, key: "base64body"
        # Whether the body was dropped from the cache and is incomplete.
        field evicted : Bool?
      end

      include Request(Result)
      METHOD = "Network.getResponseBody"

      field request_id : String

      def initialize(@request_id : String)
      end
    end

    # The `Network.requestWillBeSent` event.
    struct RequestWillBeSent
      include Message
      METHOD = "Network.requestWillBeSent"

      # Absent for redirected requests.
      field frame_id : String?
      field request_id : String
      # The request id of the request this one redirects from.
      field redirected_from : String?
      # Base64-encoded.
      field post_data : String?
      field headers : Array(HTTPHeader)
      field is_intercepted : Bool
      field url : String
      field method : String
      field navigation_id : String?
      field cause : String
      field internal_cause : String
    end

    # The `Network.responseReceived` event.
    struct ResponseReceived
      include Message
      METHOD = "Network.responseReceived"

      field security_details : SecurityDetails?, emit_null: true
      field request_id : String
      field from_cache : Bool
      field remote_ip_address : String?, key: "remoteIPAddress"
      field remote_port : Int32?
      field status : Int32
      field status_text : String
      field headers : Array(HTTPHeader)
      field timing : ResourceTiming
      field from_service_worker : Bool
    end

    # The `Network.requestFinished` event.
    struct RequestFinished
      include Message
      METHOD = "Network.requestFinished"

      field request_id : String
      field response_end_time : Float64
      field transfer_size : Int64
      field encoded_body_size : Int64
      field protocol_version : String?
    end

    # The `Network.requestFailed` event.
    struct RequestFailed
      include Message
      METHOD = "Network.requestFailed"

      field request_id : String
      field error_code : String
    end
  end
end
