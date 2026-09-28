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
  class NavigationError < Error
  end

  # Raised when a script that `Page#evaluate` runs throws.
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

  # Raised by a page, and by its waiting calls, after the page crashed.
  class PageCrashed < Error
  end

  # Raised by a page, and by its waiting calls, after the page or its
  # context was closed.
  class PageClosed < Error
  end

  # Raised when `Fetch` cannot find, download, verify or install a Camoufox
  # build.
  class FetchError < Error
  end
end
