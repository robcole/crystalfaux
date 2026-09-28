module Crystalfaux
  # The JavaScript world that `Frame#evaluate` and `Page#evaluate` run a
  # script in.
  #
  # ```
  # page.evaluate("document.title")                # isolated world
  # page.evaluate("window.appState", world: :main) # the page's own world
  # ```
  enum World
    # Camoufox's isolated sandbox, the default world of each frame. It sees
    # the DOM, but not the globals that the page's scripts set, and the
    # page cannot see it.
    Isolated

    # The world of the page's own scripts. Needs the launch config key
    # `allowMainWorld` set to `true`. The page can see and change what the
    # script uses, for example by replacing `JSON` or `Array`.
    Main
  end
end
