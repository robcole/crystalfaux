module Crystalfaux
  # A cookie that `Context#cookies` returns.
  alias Cookie = Protocol::Browser::Cookie

  # A cookie for `Context#set_cookies`. Give either `url:` or `domain:`.
  #
  # ```
  # context.set_cookies([Crystalfaux::CookieOptions.new("session", "abc", url: "https://example.com/")])
  # ```
  alias CookieOptions = Protocol::Browser::CookieOptions
end
