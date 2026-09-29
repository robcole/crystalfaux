module Crystalfaux
  # When `Page#goto` returns: the point of the new document's life that it
  # waits for. The values match Playwright's `waitUntil` option, except
  # `networkidle`.
  #
  # ```
  # page.goto(url)                                  # waits for load
  # page.goto(url, wait_until: :dom_content_loaded) # waits for DOMContentLoaded
  # page.goto(url, wait_until: :commit)             # waits for the response
  # ```
  enum WaitUntil
    # The document and its subresources, such as images and stylesheets,
    # have loaded: the `load` event.
    Load

    # The document is parsed: the `DOMContentLoaded` event. Subresources
    # can still be loading.
    DomContentLoaded

    # The browser received the response and replaced the previous
    # document with the new one. Nothing of the new document has run yet.
    Commit
  end
end
