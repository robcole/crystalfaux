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
    alias Type = Protocol::Browser::ProxyType

    getter host : String
    getter port : Int32
    getter type : Type
    getter username : String?
    getter password : String?
    getter bypass : Array(String)

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
