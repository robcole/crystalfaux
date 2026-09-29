module Crystalfaux
  # A caller's check that runs inside a click or a wait, on the caller's
  # fiber. It stops the action by raising; its return value is ignored.
  #
  # ```
  # guard = -> { raise Blocked.new if page.query_selector("#px-captcha") }
  # button.click(guard: guard)
  # page.wait_for_selector(".sku-item", guard: guard)
  # ```
  #
  # - `Page::Mouse#click` runs it after the move and before each press.
  # - `ElementHandle#click` also runs it before each try of its checks.
  # - `Frame#wait_for_function` and `Frame#wait_for_selector` run it
  #   before each poll.
  #
  # The action raises the guard's exception unchanged and sends no more
  # input or polls. The guard's time counts against the action's timeout:
  # when the deadline passes during the guard, the action raises
  # `TimeoutError` without a press.
  alias Guard = Proc(Nil)
end
