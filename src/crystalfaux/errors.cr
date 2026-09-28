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

  # Raised when the pipe to the browser is closed, or closes while a request
  # waits for its reply.
  class ConnectionClosed < Error
  end
end
