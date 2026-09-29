module Crystalfaux::Protocol
  # The `Browser` domain: root-session methods and events for contexts,
  # page targets and cookies. The structs sit in one file because each is a
  # small value type of the same schema section.
  module Browser
    # The `TargetType` enum of the Juggler schema.
    Protocol.wire_enum(TargetType, page: "page")
    # The `SameSite` enum of the Juggler schema.
    Protocol.wire_enum(SameSite, strict: "Strict", lax: "Lax", none: "None")
    # The protocol of a proxy server: `http`, `https`, `socks` or `socks4`.
    Protocol.wire_enum(ProxyType, http: "http", https: "https", socks: "socks", socks4: "socks4")

    # The `TargetInfo` type of the Juggler schema.
    struct TargetInfo
      include Message

      field type : TargetType
      field target_id : String
      field browser_context_id : String?
      # The target id of the page that opened this one, if any.
      field opener_id : String?
    end

    # The `UserPreference` type of the Juggler schema.
    struct UserPreference
      include Message

      field name : String
      field value : JSON::Any

      def initialize(@name : String, @value : JSON::Any)
      end
    end

    # A cookie to set. Give either *url* or *domain*.
    struct CookieOptions
      include Message

      field name : String
      field value : String
      field url : String?
      field domain : String?
      field path : String?
      field secure : Bool?
      field http_only : Bool?
      field same_site : SameSite?
      # Seconds since the epoch; `nil` makes a session cookie.
      field expires : Float64?

      def initialize(@name : String, @value : String, *, @url : String? = nil, @domain : String? = nil,
                     @path : String? = nil, @secure : Bool? = nil, @http_only : Bool? = nil,
                     @same_site : SameSite? = nil, @expires : Float64? = nil)
      end
    end

    # A cookie of a browser context, as `Browser.getCookies` returns it.
    struct Cookie
      include Message

      field name : String
      field domain : String
      field path : String
      field value : String
      # Seconds since the epoch, or `-1` for a session cookie.
      field expires : Float64
      field size : Int32
      field http_only : Bool
      field secure : Bool
      field session : Bool
      field same_site : SameSite
    end

    # The `Browser.enable` request.
    struct Enable
      include Message
      include Request(Empty)
      METHOD = "Browser.enable"

      field attach_to_default_context : Bool
      field user_prefs : Array(UserPreference)?

      def initialize(@attach_to_default_context : Bool, @user_prefs : Array(UserPreference)? = nil)
      end
    end

    # The `Browser.getInfo` request.
    struct GetInfo
      include Message

      # The result of `Browser.getInfo`.
      struct Result
        include Message

        field user_agent : String
        # For example `"Firefox/152.0.4-beta.31"`.
        field version : String
      end

      include Request(Result)
      METHOD = "Browser.getInfo"

      def initialize
      end
    end

    # The `Browser.createBrowserContext` request.
    struct CreateBrowserContext
      include Message

      # The result of `Browser.createBrowserContext`.
      struct Result
        include Message

        field browser_context_id : String
      end

      include Request(Result)
      METHOD = "Browser.createBrowserContext"

      field remove_on_detach : Bool?

      def initialize(@remove_on_detach : Bool? = nil)
      end
    end

    # The `Browser.removeBrowserContext` request.
    struct RemoveBrowserContext
      include Message
      include Request(Empty)
      METHOD = "Browser.removeBrowserContext"

      field browser_context_id : String

      def initialize(@browser_context_id : String)
      end
    end

    # Opens a page. Its session arrives in `AttachedToTarget`, which the
    # browser sends before this reply.
    struct NewPage
      include Message

      # The result of `Browser.newPage`.
      struct Result
        include Message

        field target_id : String
      end

      include Request(Result)
      METHOD = "Browser.newPage"

      field browser_context_id : String?

      def initialize(@browser_context_id : String? = nil)
      end
    end

    # Asks the browser to close. Send it with `Juggler::Connection#notify`:
    # the reply may never come, and the process keeps running until the pipe
    # closes (see `Launcher::BrowserProcess#close`).
    struct Close
      include Message
      include Request(Empty)
      METHOD = "Browser.close"

      def initialize
      end
    end

    # The `Browser.setExtraHTTPHeaders` request.
    struct SetExtraHTTPHeaders
      include Message
      include Request(Empty)
      METHOD = "Browser.setExtraHTTPHeaders"

      field browser_context_id : String?
      field headers : Array(Network::HTTPHeader)

      def initialize(@headers : Array(Network::HTTPHeader), @browser_context_id : String? = nil)
      end
    end

    # The `Browser.setBrowserProxy` request.
    struct SetBrowserProxy
      include Message
      include Request(Empty)
      METHOD = "Browser.setBrowserProxy"

      field type : ProxyType
      field bypass : Array(String)
      field host : String
      field port : Int32
      field username : String?
      field password : String?

      def initialize(@type : ProxyType, @host : String, @port : Int32, @bypass : Array(String),
                     @username : String? = nil, @password : String? = nil)
      end
    end

    # The `Browser.setContextProxy` request.
    struct SetContextProxy
      include Message
      include Request(Empty)
      METHOD = "Browser.setContextProxy"

      field browser_context_id : String?
      field type : ProxyType
      field bypass : Array(String)
      field host : String
      field port : Int32
      field username : String?
      field password : String?

      def initialize(@browser_context_id : String?, @type : ProxyType, @host : String, @port : Int32,
                     @bypass : Array(String), @username : String? = nil, @password : String? = nil)
      end
    end

    # The `Browser.setRequestInterception` request.
    struct SetRequestInterception
      include Message
      include Request(Empty)
      METHOD = "Browser.setRequestInterception"

      field browser_context_id : String?
      field enabled : Bool

      def initialize(@enabled : Bool, @browser_context_id : String? = nil)
      end
    end

    # The `Browser.setCookies` request.
    struct SetCookies
      include Message
      include Request(Empty)
      METHOD = "Browser.setCookies"

      field browser_context_id : String?
      field cookies : Array(CookieOptions)

      def initialize(@cookies : Array(CookieOptions), @browser_context_id : String? = nil)
      end
    end

    # The `Browser.clearCookies` request.
    struct ClearCookies
      include Message
      include Request(Empty)
      METHOD = "Browser.clearCookies"

      field browser_context_id : String?

      def initialize(@browser_context_id : String? = nil)
      end
    end

    # The `Browser.getCookies` request.
    struct GetCookies
      include Message

      # The result of `Browser.getCookies`.
      struct Result
        include Message

        field cookies : Array(Cookie)
      end

      include Request(Result)
      METHOD = "Browser.getCookies"

      field browser_context_id : String?

      def initialize(@browser_context_id : String? = nil)
      end
    end

    # A page target is ready; its events and requests use *session_id*.
    struct AttachedToTarget
      include Message
      METHOD = "Browser.attachedToTarget"

      field session_id : String
      field target_info : TargetInfo
    end

    # The `Browser.detachedFromTarget` event.
    struct DetachedFromTarget
      include Message
      METHOD = "Browser.detachedFromTarget"

      field session_id : String
      field target_id : String
    end
  end
end
