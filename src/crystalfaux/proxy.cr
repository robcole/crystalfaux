module Crystalfaux
  # A proxy server for a browser (`Browser.launch(proxy:)`) or for one
  # context (`Browser#new_context(proxy:)`).
  #
  # The fields are those of Juggler's `Browser.setBrowserProxy` and
  # `Browser.setContextProxy` (Camoufox
  # `additions/juggler/protocol/Protocol.js`). *bypass* lists the hosts
  # that connect directly, for example `".internal"` or `"localhost"`.
  #
  # ```
  # proxy = Crystalfaux::Proxy.new("proxy.example", 3128, username: "me", password: "secret")
  # context = browser.new_context(proxy: proxy)
  # ```
  #
  # `#inspect` and `#to_s` do not show the password.
  struct Proxy
    # The protocol of the proxy server.
    alias Type = Protocol::Browser::ProxyType

    # The host name or IP address of the proxy server.
    getter host : String
    # The port of the proxy server.
    getter port : Int32
    # The protocol of the proxy server; `Type::Http` by default.
    getter type : Type
    # The user name for proxy authentication, if any.
    getter username : String?
    # The password for proxy authentication, if any.
    getter password : String?
    # The hosts that connect without the proxy.
    getter bypass : Array(String)

    # Describes the proxy server at *host* and *port*.
    def initialize(@host : String, @port : Int32, *, @type : Type = Type::Http, @username : String? = nil,
                   @password : String? = nil, @bypass : Array(String) = [] of String)
    end

    def to_s(io : IO) : Nil
      io << type.wire_name << "://"
      username.try { |name| io << name << (password ? ":****" : "") << '@' }
      io << host << ':' << port
    end

    def inspect(io : IO) : Nil
      io << "#<Crystalfaux::Proxy " << self << " bypass=" << bypass << '>'
    end
  end
end
