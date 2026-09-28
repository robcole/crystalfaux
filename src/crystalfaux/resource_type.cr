module Crystalfaux
  # What a request loads, as Playwright names it.
  #
  # ```
  # context.block(types: [Crystalfaux::ResourceType::Image, Crystalfaux::ResourceType::Font])
  # ```
  enum ResourceType
    Document
    Stylesheet
    Image
    Media
    Font
    Script
    Xhr
    Fetch
    EventSource
    WebSocket
    Manifest
    Other

    # Maps the `cause` and `internalCause` of `Network.requestWillBeSent`
    # (Firefox `nsIContentPolicy` type names) as Playwright's
    # `server/firefox/ffNetworkManager.ts` does. Unknown causes are `Other`.
    def self.from_cause(cause : String, internal_cause : String) : self
      return EventSource if internal_cause == "TYPE_INTERNAL_EVENTSOURCE"
      case cause
      when "TYPE_DOCUMENT", "TYPE_SUBDOCUMENT", "TYPE_REFRESH" then Document
      when "TYPE_STYLESHEET"                                   then Stylesheet
      when "TYPE_IMAGE", "TYPE_IMAGESET"                       then Image
      when "TYPE_MEDIA"                                        then Media
      when "TYPE_FONT"                                         then Font
      when "TYPE_SCRIPT"                                       then Script
      when "TYPE_XMLHTTPREQUEST"                               then Xhr
      when "TYPE_FETCH"                                        then Fetch
      when "TYPE_WEBSOCKET"                                    then WebSocket
      when "TYPE_WEB_MANIFEST"                                 then Manifest
      else                                                          Other
      end
    end
  end
end
