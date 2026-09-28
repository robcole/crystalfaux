require "wait_group"

module Crystalfaux
  # A fixed number of browsers that serve one page at a time each. The pool
  # replaces a browser after it served `pages_per_browser` pages, and when
  # it crashed or its pipe closed.
  #
  # ```
  # options = Crystalfaux::Launcher::Options.new(headless: true)
  # pool = Crystalfaux::Pool.new(size: 2, pages_per_browser: 50) do |number|
  #   # *number* counts launches from 0, so each browser can get its own
  #   # config.
  #   Crystalfaux::Browser.launch(options)
  # end
  # title = pool.with_page do |page|
  #   page.goto("https://example.com/")
  #   page.title
  # end
  # pool.close
  # ```
  #
  # Ownership:
  #
  # - The pool owns every browser that the launch block returns, and closes
  #   it when the browser is replaced or the pool closes. Do not close a
  #   pool browser from a `#with_page` block.
  # - `#with_page` owns the page and its context. It closes both after the
  #   block, also when the block raises.
  #
  # Replacement: the pool keeps no fiber running. A `#with_page` call
  # launches a browser, in the caller's fiber, when its slot has none: on
  # the first use of the slot, and after a replacement. At the end of the
  # call, the pool closes the browser in the caller's fiber when it served
  # `pages_per_browser` pages, its page crashed (`Page.crashed`), closing
  # the page failed, or its connection closed (pipe EOF or process exit).
  # A browser whose pipe closes while no call uses it is closed at the next
  # call that gets it.
  #
  # Shutdown: `#close` returns only after every browser the pool launched
  # has stopped and its profile is removed. It closes the browsers in the
  # slots, then waits for the launches and replacements that other fibers
  # have in progress. A launch that returns after `#close` started closes
  # its browser before `#close` returns. After `#close` started, it alone
  # closes the browsers in the slots; a `#with_page` call that ends then
  # leaves its browser to it. `#close` does not wait for `#with_page`
  # blocks.
  #
  # The pool puts no deadline on the launch block. `#close` waits as long as
  # a launch in progress takes, so the launch block must bound its own time,
  # as `Browser.launch` does with its *timeout*. Browser shutdown is bounded
  # by `Launcher::BrowserProcess#close`, which kills a process that does not
  # stop in its grace period. The launch block must not call `#close` of its
  # own pool: that call raises `PoolError`.
  #
  # A block whose browser or page dies while it runs gets the error of its
  # next call: `PageCrashed`, `ConnectionClosed` or `PageClosed`. The pool
  # does not retry the block; it replaces the browser for the next call.
  class Pool
    # How long closing the page and context of a `#with_page` call may
    # take, for each request.
    CLOSE_TIMEOUT = 5.seconds

    # The number of browsers, which is also the number of blocks that can
    # run at once.
    getter size : Int32

    # The number of pages a browser serves before the pool replaces it.
    getter pages_per_browser : Int32

    @lock = Sync::Mutex.new
    @closed = false
    @launches = 0
    # Counts the launches, browser shutdowns, and `#close` calls in
    # progress. Each one is added with `@lock` held while the pool is open,
    # so nothing is added after `#close` starts to wait.
    @busy = WaitGroup.new
    # The fibers that run the launch block now.
    @launching = Set(Fiber).new

    # Makes a pool of *size* browsers. The pool calls *launch* with a launch
    # number (0, 1, 2, ...) each time it needs a browser; it launches none
    # before the first `#with_page`.
    def initialize(*, @size : Int32, @pages_per_browser : Int32, &@launch : Int32 -> Browser)
      raise ArgumentError.new("Pool size must be at least 1, not #{@size}") if @size < 1
      raise ArgumentError.new("pages_per_browser must be at least 1, not #{@pages_per_browser}") if @pages_per_browser < 1
      @slots = Array(Slot).new(@size) { Slot.new }
      # Holds the slots that no call uses, oldest first.
      @idle = Channel(Slot).new(@size)
      @slots.each { |slot| @idle.send(slot) }
    end

    # Waits for an idle browser, opens a page in a new context of it, and
    # yields the page. Closes the page and the context after the block and
    # returns the block's value.
    #
    # Raises `PoolClosed` when the pool is closed, or closes during the wait.
    # Raises what the launch block raises when a launch fails; the next call
    # launches again. Raises what the block raises; the pool does not retry
    # it.
    def with_page(& : Page -> T) : T forall T
      slot = checkout
      begin
        page = open_page(slot, browser_for(slot))
        begin
          yield page
        ensure
          release(slot, page)
        end
      ensure
        checkin(slot)
      end
    end

    # Closes every browser, including browsers that a `#with_page` block
    # uses: that block gets `ConnectionClosed` from its next call. Wakes
    # the calls that wait for a browser with `PoolClosed`. Returns when
    # every browser of the pool has stopped (see "Shutdown" above). Safe to
    # call more than once; each call waits.
    #
    # Raises `PoolError`, and changes nothing, when the launch block calls
    # it: `#close` waits for that launch, which would never end.
    def close : Nil
      browsers = @lock.synchronize do
        raise PoolError.new("Pool#close called from the pool's launch block") if @launching.includes?(Fiber.current)
        next if @closed
        @closed = true
        @idle.close
        @busy.add
        @slots.compact_map(&.browser)
      end
      if browsers
        begin
          browsers.each(&.close)
        ensure
          @busy.done
        end
      end
      @busy.wait
    end

    def closed? : Bool
      @lock.synchronize { @closed }
    end

    private def checkout : Slot
      slot = @idle.receive?
      # A closed channel can still hold slots; the pool no longer hands
      # them out.
      raise PoolClosed.new("Pool is closed") if slot.nil? || closed?
      slot
    end

    # Returns the slot's browser, or a new one when it has none or its
    # connection closed.
    private def browser_for(slot : Slot) : Browser
      browser = slot.browser
      return browser if browser && !browser.closed?
      retire(slot)
      launch(slot)
    end

    private def launch(slot : Slot) : Browser
      number = @lock.synchronize do
        raise PoolClosed.new("Pool is closed") if @closed
        @busy.add
        @launching << Fiber.current
        @launches.tap { @launches += 1 }
      end
      begin
        browser = begin
          @launch.call(number)
        ensure
          @lock.synchronize { @launching.delete(Fiber.current) }
        end
        closed = @lock.synchronize do
          slot.assign(browser) unless @closed
          @closed
        end
        return browser unless closed
        # `#close` ran during the launch and did not see this browser; it
        # waits for this close.
        browser.close
        raise PoolClosed.new("Pool is closed")
      ensure
        @busy.done
      end
    end

    # Opens a page in a new context. On failure, the pool replaces the
    # browser.
    private def open_page(slot : Slot, browser : Browser) : Page
      slot.served += 1
      context = browser.new_context
      begin
        context.new_page
      rescue ex
        close_quietly { context.close(CLOSE_TIMEOUT) }
        raise ex
      end
    rescue ex
      slot.failed = true
      raise ex
    end

    # Closes *page* and its context. Does not raise, so the block's own
    # error stays. A crashed page, or a failure to close, marks the browser
    # for replacement. The page of a crashed browser is not closed: the
    # browser may not answer, and it is closed soon.
    private def release(slot : Slot, page : Page) : Nil
      if page.crashed?
        slot.failed = true
        return
      end
      context = page.context
      closed = close_quietly do
        page.close(CLOSE_TIMEOUT)
        context.close(CLOSE_TIMEOUT)
      end
      slot.failed = true unless closed
    end

    # Runs the block, and returns `false` instead of raising an `Error`.
    private def close_quietly(& : ->) : Bool
      yield
      true
    rescue Error
      false
    end

    # Closes the slot's browser when it is used up or dead, then gives the
    # slot back to the idle slots, unless the pool is closed.
    private def checkin(slot : Slot) : Nil
      retire(slot) if worn_out?(slot)
      @lock.synchronize do
        # `#close` closed the slot's browser; the slot is not reused.
        return if @closed
        @idle.send(slot)
      end
    end

    private def worn_out?(slot : Slot) : Bool
      browser = slot.browser
      return false unless browser
      slot.failed? || slot.served >= @pages_per_browser || browser.closed?
    end

    # Takes the slot's browser, if any, and closes it. `#close` waits for
    # that shutdown. When the pool is closed, `#close` owns the browser, so
    # this leaves it in the slot and does not close it.
    private def retire(slot : Slot) : Nil
      browser = @lock.synchronize do
        next if @closed
        slot.take.tap { |taken| @busy.add if taken }
      end
      return unless browser
      begin
        browser.close
      ensure
        @busy.done
      end
    end

    # :nodoc:
    #
    # One browser place of the pool. The fiber that checked the slot out
    # reads and writes it; `@lock` guards `#browser` changes, which
    # `Pool#close` reads.
    private class Slot
      getter browser : Browser?
      # Pages opened on the current browser.
      property served = 0
      # Whether the current browser must be replaced.
      property? failed = false

      def assign(browser : Browser) : Nil
        @browser = browser
        @served = 0
        @failed = false
      end

      def take : Browser?
        @browser.tap { @browser = nil }
      end
    end
  end
end
