module Crystalfaux
  # Base class for every error that crystalfaux raises.
  class Error < Exception
  end

  # Raised when the browser answers a request with an error.
  #
  # ```
  # connection.call("Browser.setDefaultViewport", {viewport: nil})
  # # raises Crystalfaux::ProtocolError:
  # #   "Protocol error (Browser.setDefaultViewport): ..."
  # ```
  class ProtocolError < Error
    # The request method that failed, for example `"Page.navigate"`.
    getter method : String

    def initialize(@method : String, reason : String)
      super("Protocol error (#{@method}): #{reason}")
    end
  end

  # Raised when a request gets no reply before its deadline.
  class TimeoutError < Error
  end

  # Raised when the browser cannot be started: the executable is missing,
  # or the browser exits or stays silent before it is ready.
  class LaunchError < Error
  end

  # Raised when the pipe to the browser is closed, or closes while a request
  # waits for its reply.
  class ConnectionClosed < Error
  end

  # Raised when a Camoufox install has a version that the vendored protocol
  # does not support, or no readable `version.json`.
  class UnsupportedBrowserError < Error
  end

  # Raised when a navigation fails before its document commits, for example
  # when another navigation replaces it.
  #
  # A navigation can fail after its response arrived. For example, Camoufox
  # aborts a navigation to an error status with an empty body, such as a
  # 404 or a 403 block page, with `NS_ERROR_NET_EMPTY_RESPONSE`. Then
  # `#response` is that response:
  #
  # ```
  # begin
  #   page.goto(url)
  # rescue ex : Crystalfaux::NavigationError
  #   ex.response.try(&.status) # => 404
  # end
  # ```
  class NavigationError < Error
    # The response of the navigation's document, when it arrived before the
    # navigation failed.
    getter response : Response?

    def initialize(message : String, @response : Response? = nil)
      super(message)
    end
  end

  # Raised when a script that `Frame#evaluate` or `Page#evaluate` runs
  # throws, or returns a value that JSON cannot carry.
  #
  # ```
  # page.evaluate("throw new Error('boom')")
  # # raises Crystalfaux::EvaluationError: "boom"
  # ```
  class EvaluationError < Error
    # The JavaScript stack of the thrown `Error`, if the script threw one.
    getter stack : String?

    def initialize(message : String, @stack : String? = nil)
      super(message)
    end
  end

  # Raised by `Frame#evaluate` and `Page#evaluate` when the frame has no
  # execution context, or its context is destroyed before the script
  # returns: by a navigation, or because the frame was detached. Evaluate
  # again after the navigation.
  #
  # An `ElementHandle` raises it too once the context it was made in is
  # gone: query the element again.
  class ExecutionContextDestroyed < Error
  end

  # Raised by an `ElementHandle` action, such as `ElementHandle#click`, when
  # the element's node is no longer in its document, for example because
  # the page re-rendered it. Query the element again.
  class ElementDetached < Error
  end

  # Raised by a call on an `ElementHandle` after `ElementHandle#dispose`,
  # and by an evaluation that gets a disposed handle as an argument. The
  # evaluation sends nothing.
  class HandleDisposed < Error
  end

  # Raised by an evaluation that gets an `ElementHandle` of another
  # execution context as an argument: a handle of another frame, or of an
  # earlier document of the same frame. The evaluation sends nothing.
  #
  # ```
  # page.evaluate("el => el.id", {frame.query_selector("#go")})
  # # raises Crystalfaux::ForeignHandle
  # ```
  class ForeignHandle < Error
  end

  # Raised by a page, and by its waiting calls, after the page crashed.
  class PageCrashed < Error
  end

  # Raised by a page, and by its waiting calls, after the page or its
  # context was closed.
  class PageClosed < Error
  end

  # Raised when a `Pool` is used in a way it does not support, for example
  # when its launch block calls `Pool#close`. Base class of `PoolClosed`.
  class PoolError < Error
  end

  # Raised by `Pool#with_page` after `Pool#close`, and by a call that waits
  # for a browser when the pool closes.
  class PoolClosed < PoolError
  end

  # Raised when `Fetch` cannot find, download, verify or install a Camoufox
  # build.
  class FetchError < Error
  end

  # Raised when a fingerprint config has an unknown key, a value of the
  # wrong type, or a user agent that does not match its OS.
  class ConfigError < Error
  end

  # Raised when a Firefox pref value is not a bool, a string or an integer
  # in the signed 32-bit range (see `Launcher.check_prefs`).
  class PrefError < Error
  end
end
