module Crystalfaux::Protocol
  # The `Network` domain: per-page request interception and request
  # lifecycle events. The structs sit in one file because each is a small
  # value type of the same schema section.
  module Network
    struct HTTPHeader
      include Message

      field name : String
      field value : String

      def initialize(@name : String, @value : String)
      end
    end

    struct SecurityDetails
      include Message

      field protocol : String
      field subject_name : String
      field issuer : String
      field valid_from : Float64
      field valid_to : Float64
    end

    # Milliseconds relative to `start_time`; `-1` when a phase did not run.
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

    struct SetRequestInterception
      include Message
      include Request(Empty)
      METHOD = "Network.setRequestInterception"

      field enabled : Bool

      def initialize(@enabled : Bool)
      end
    end

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

    struct GetResponseBody
      include Message

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

    struct RequestWillBeSent
      include Message
      METHOD = "Network.requestWillBeSent"

      # Absent for redirected requests.
      field frame_id : String?
      field request_id : String
      # The request id of the request this one redirects from.
      field redirected_from : String?
      field post_data : String?
      field headers : Array(HTTPHeader)
      field is_intercepted : Bool
      field url : String
      field method : String
      field navigation_id : String?
      field cause : String
      field internal_cause : String
    end

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

    struct RequestFinished
      include Message
      METHOD = "Network.requestFinished"

      field request_id : String
      field response_end_time : Float64
      field transfer_size : Int64
      field encoded_body_size : Int64
      field protocol_version : String?
    end

    struct RequestFailed
      include Message
      METHOD = "Network.requestFailed"

      field request_id : String
      field error_code : String
    end
  end
end
