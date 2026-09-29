module Crystalfaux::Juggler
  # A handler registered with `Connection#on`. Pass it to `Connection#off` to
  # stop receiving events.
  class Subscription
    # The event method, for example `"Page.eventFired"`.
    getter method : String

    # The session the event must come from, or `nil` for the root session.
    getter session_id : String?

    # :nodoc:
    getter handler : JSON::Any ->

    def initialize(@method : String, @session_id : String?, @handler : JSON::Any ->)
    end
  end
end
