module Crystalfaux
  # The state that `Frame#wait_for_selector` waits for, as in Playwright:
  #
  # - `Attached`: an element matches.
  # - `Visible`: an element matches and is visible (see
  #   `ElementHandle#visible?`).
  # - `Hidden`: no element matches, or it is not visible.
  # - `Detached`: no element matches.
  enum ElementState
    Attached
    Visible
    Hidden
    Detached

    # The name that `DomScripts::WAIT_FOR_SELECTOR` takes.
    def script_name : String
      to_s.downcase
    end
  end
end
