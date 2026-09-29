require "../../spec_helper"

# Returns the params of the next *count* requests for *method*.
private def params_of(fake : ScriptedBrowser, method : String, count : Int32) : Array(JSON::Any)
  Array.new(count) { fake.request(method)["params"] }
end

# Acknowledges each mouse event except `mousedown`, whose reply never comes.
private def withhold_press(fake : ScriptedBrowser) : Nil
  fake.on("Page.dispatchMouseEvent") do |request|
    request["params"]["type"] == "mousedown" ? [] of JSON::Any : [json_frame({id: 0})]
  end
end

# What a caller's guard raises when it sees a challenge.
private class ChallengeSeen < Exception
end

describe Crystalfaux::Page::Mouse do
  it "clicks with a move, a down and an up at the point" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    page.mouse.click(10.5, 20)

    params_of(fake, "Page.dispatchMouseEvent", 3).should eq([
      json_frame({type: "mousemove", button: 0, x: 10.0, y: 20.0, modifiers: 0, buttons: 0}),
      json_frame({type: "mousedown", button: 0, x: 10.0, y: 20.0, modifiers: 0, clickCount: 1, buttons: 1}),
      json_frame({type: "mouseup", button: 0, x: 10.0, y: 20.0, modifiers: 0, clickCount: 1, buttons: 0}),
    ])
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "reports held buttons while it moves, and a double click as two clicks" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page
    mouse = page.mouse

    mouse.down(button: :right)
    mouse.move(4, 8, steps: 2)
    mouse.up(button: :right)
    mouse.click(4, 8, click_count: 2)

    params_of(fake, "Page.dispatchMouseEvent", 9).map { |event| {event["type"], event["x"], event["buttons"], event["clickCount"]?} }.should eq([
      {"mousedown", 0.0, 2, 1},
      {"mousemove", 2.0, 2, nil},
      {"mousemove", 4.0, 2, nil},
      {"mouseup", 4.0, 0, 1},
      {"mousemove", 4.0, 0, nil},
      {"mousedown", 4.0, 1, 1},
      {"mouseup", 4.0, 0, 1},
      {"mousedown", 4.0, 1, 2},
      {"mouseup", 4.0, 0, 2},
    ].map { |type, x, buttons, count| {JSON::Any.new(type), JSON::Any.new(x), JSON::Any.new(buttons.to_i64), count.try { |value| JSON::Any.new(value.to_i64) }} })
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "waits for an animation frame, then scrolls at its position with held modifiers" do
    browser, fake = scripted_browser
    page = loaded_page(browser)
    fake.on("Runtime.evaluate") { [json_frame({id: 0, result: {} of String => String})] }

    page.mouse.move(30, 40)
    page.keyboard.down("Shift")
    page.mouse.wheel(0, 120)

    fake.request("Runtime.evaluate")["params"]["expression"].should eq(JSON::Any.new("new Promise(requestAnimationFrame)"))
    fake.request("Page.dispatchWheelEvent")["params"].should eq(
      json_frame({x: 30.0, y: 40.0, deltaX: 0.0, deltaY: 120.0, deltaZ: 0.0, modifiers: 4}))
    methods = fake.methods
    methods.index!("Runtime.evaluate").should be < methods.index!("Page.dispatchWheelEvent")
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "sends each held modifier as Firefox's modifier bit" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page

    expected = {"Alt" => 1, "Control" => 2, "Shift" => 4, "Meta" => 8}
    sent = expected.keys.to_h do |key|
      page.keyboard.down(key)
      page.mouse.down
      page.mouse.up
      page.keyboard.up(key)
      down, up = Array.new(2) { fake.request("Page.dispatchMouseEvent")["params"]["modifiers"].as_i }
      down.should eq(up)
      {key, down}
    end

    sent.should eq(expected)
  ensure
    browser.try &.close
    fake.try &.close
  end

  it "raises PageCrashed on a crashed page" do
    browser, fake = scripted_browser
    page = browser.new_context.new_page
    fake.event("Page.crashed", {} of String => String)
    page.wait_for_events_for_spec

    expect_raises(Crystalfaux::PageCrashed) { page.mouse.click(1, 1) }
  ensure
    browser.try &.close
    fake.try &.close
  end

  describe "when the press is interrupted" do
    it "releases the button once when the press is not acknowledged in time" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      withhold_press(fake)
      page.keyboard.down("Shift")

      error = expect_raises(Crystalfaux::TimeoutError) { page.mouse.click(10, 20, :right, timeout: 200.milliseconds) }
      page.mouse.move(30, 40)

      message = error.message.to_s
      message.should contain("mousedown")
      message.should contain("uncertain")
      params_of(fake, "Page.dispatchMouseEvent", 4).should eq([
        json_frame({type: "mousemove", button: 0, x: 10.0, y: 20.0, modifiers: 4, buttons: 0}),
        json_frame({type: "mousedown", button: 2, x: 10.0, y: 20.0, modifiers: 4, clickCount: 1, buttons: 2}),
        json_frame({type: "mouseup", button: 2, x: 10.0, y: 20.0, modifiers: 4, clickCount: 1, buttons: 0}),
        json_frame({type: "mousemove", button: 0, x: 30.0, y: 40.0, modifiers: 4, buttons: 0}),
      ])
      fake.methods.count("Page.dispatchMouseEvent").should eq(4)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "releases the button when a single press is not acknowledged in time" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      withhold_press(fake)

      expect_raises(Crystalfaux::TimeoutError, "mousedown") { page.mouse.down(timeout: 200.milliseconds) }
      page.mouse.move(5, 5)

      params_of(fake, "Page.dispatchMouseEvent", 3).map { |event| {event["type"].as_s, event["buttons"].as_i} }.should eq([
        {"mousedown", 1}, {"mouseup", 0}, {"mousemove", 0},
      ])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises TimeoutError when the release is acknowledged after the deadline" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.dispatchMouseEvent") do |request|
        sleep 400.milliseconds if request["params"]["type"] == "mouseup"
        [json_frame({id: 0})]
      end

      expect_raises(Crystalfaux::TimeoutError, "mouseup") { page.mouse.click(10, 20, timeout: 100.milliseconds) }
      page.mouse.move(30, 40)

      params_of(fake, "Page.dispatchMouseEvent", 4).map { |event| {event["type"].as_s, event["buttons"].as_i} }.should eq([
        {"mousemove", 0}, {"mousedown", 1}, {"mouseup", 0}, {"mousemove", 0},
      ])
      fake.methods.count("Page.dispatchMouseEvent").should eq(4)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "keeps the timeout as the cause and names the release when the cleanup fails" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      fake.on("Page.dispatchMouseEvent") do |request|
        request["params"]["type"] == "mousemove" ? [json_frame({id: 0})] : [] of JSON::Any
      end

      started = Time.instant
      error = expect_raises(Crystalfaux::TimeoutError) { page.mouse.click(10, 20, timeout: 100.milliseconds) }
      (Time.instant - started).should be < 3.seconds
      page.mouse.move(30, 40)

      error.message.to_s.should contain("Releasing the button failed")
      error.cause.should be_a(Crystalfaux::TimeoutError)
      params_of(fake, "Page.dispatchMouseEvent", 4).map { |event| {event["type"].as_s, event["buttons"].as_i} }.should eq([
        {"mousemove", 0}, {"mousedown", 1}, {"mouseup", 0}, {"mousemove", 0},
      ])
      fake.methods.count("Page.dispatchMouseEvent").should eq(4)
    ensure
      browser.try &.close
      fake.try &.close
    end

    # A mouse request is cancelled only by the page's own cancellation,
    # which closing the page or a crash fires: the page is then gone while
    # the transport still works.
    it "keeps the page's failure and sends no release when the press is cancelled" do
      {
        "crash" => ->(_page : Crystalfaux::Page, fake : ScriptedBrowser) { fake.event("Page.crashed", {} of String => String) },
        "close" => ->(page : Crystalfaux::Page, _fake : ScriptedBrowser) { page.close },
      }.each do |name, cancel|
        browser, fake = scripted_browser
        page = browser.new_context.new_page
        withhold_press(fake)

        result = async do
          page.mouse.click(1, 1, timeout: 5.seconds)
          JSON::Any.new(nil)
        end
        fake.request("Page.dispatchMouseEvent")
        fake.request("Page.dispatchMouseEvent")["params"]["type"].should eq(JSON::Any.new("mousedown"))
        cancel.call(page, fake)

        error = receive_within(result).should(be_a(Exception))
        (error.is_a?(Crystalfaux::PageCrashed) || error.is_a?(Crystalfaux::PageClosed)).should be_true, "#{name}: #{error.inspect}"
        page.wait_for_events_for_spec
        fake.methods.count("Page.dispatchMouseEvent").should eq(2), name
      ensure
        browser.try &.close
        fake.try &.close
      end
    end

    it "raises the closed connection without hanging when the transport dies during the press" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      withhold_press(fake)

      result = async do
        page.mouse.click(1, 1, timeout: 5.seconds)
        JSON::Any.new(nil)
      end
      fake.request("Page.dispatchMouseEvent")
      fake.request("Page.dispatchMouseEvent")
      fake.close

      error = receive_within(result).should(be_a(Crystalfaux::ConnectionClosed))
      error.message.to_s.should_not contain("mouseup")
    ensure
      browser.try &.close
      fake.try &.close
    end
  end

  describe "with a guard" do
    it "runs the guard after the move is acknowledged and before the press" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      move_acknowledged = Channel(Time::Instant).new(1)
      fake.on("Page.dispatchMouseEvent") do |request|
        if request["params"]["type"] == "mousemove"
          sleep 50.milliseconds
          move_acknowledged.send(Time.instant)
        end
        [json_frame({id: 0})]
      end
      seen = [] of {Time::Instant, Array(String), Fiber}
      guard = -> { seen << {Time.instant, fake.methods, Fiber.current} }

      page.mouse.click(10, 20, guard: guard)

      seen.size.should eq(1)
      guarded_at, methods, fiber = seen.first
      fiber.should be(Fiber.current)
      guarded_at.should be >= receive_within(move_acknowledged)
      methods.count("Page.dispatchMouseEvent").should eq(1)
      params_of(fake, "Page.dispatchMouseEvent", 3).map(&.["type"].as_s).should eq(%w[mousemove mousedown mouseup])
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "sends no press and raises the guard's exception unchanged when the guard raises" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      challenge = ChallengeSeen.new("challenge")

      error = expect_raises(ChallengeSeen) { page.mouse.click(10, 20, guard: -> { raise challenge }) }
      page.wait_for_events_for_spec

      error.should be(challenge)
      fake.methods.count("Page.dispatchMouseEvent").should eq(1)
      fake.request("Page.dispatchMouseEvent")["params"]["type"].should eq(JSON::Any.new("mousemove"))
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "raises a TimeoutError from the guard unchanged" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      own = Crystalfaux::TimeoutError.new("the caller's own timeout")

      error = expect_raises(Crystalfaux::TimeoutError) { page.mouse.click(10, 20, guard: -> { raise own }) }

      error.should be(own)
      fake.methods.count("Page.dispatchMouseEvent").should eq(1)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "sends no press when the guard runs past the deadline" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page

      expect_raises(Crystalfaux::TimeoutError, "mousedown") do
        page.mouse.click(10, 20, timeout: 100.milliseconds, guard: -> { sleep 200.milliseconds })
      end
      page.wait_for_events_for_spec

      fake.methods.count("Page.dispatchMouseEvent").should eq(1)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "runs before each press of a double click" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      calls = 0
      guard = -> do
        calls += 1
        raise ChallengeSeen.new("challenge") if calls == 2
      end

      expect_raises(ChallengeSeen) { page.mouse.click(10, 20, click_count: 2, guard: guard) }
      page.wait_for_events_for_spec

      params_of(fake, "Page.dispatchMouseEvent", 3).map { |event| {event["type"].as_s, event["buttons"].as_i} }.should eq([
        {"mousemove", 0}, {"mousedown", 1}, {"mouseup", 0},
      ])
      fake.methods.count("Page.dispatchMouseEvent").should eq(3)
    ensure
      browser.try &.close
      fake.try &.close
    end

    it "keeps the release cleanup of a press that was sent" do
      browser, fake = scripted_browser
      page = browser.new_context.new_page
      withhold_press(fake)
      calls = 0

      error = expect_raises(Crystalfaux::TimeoutError) do
        page.mouse.click(10, 20, timeout: 200.milliseconds, guard: -> { calls += 1; nil })
      end
      page.mouse.move(30, 40)

      calls.should eq(1)
      error.message.to_s.should contain("mousedown")
      params_of(fake, "Page.dispatchMouseEvent", 4).map { |event| {event["type"].as_s, event["buttons"].as_i} }.should eq([
        {"mousemove", 0}, {"mousedown", 1}, {"mouseup", 0}, {"mousemove", 0},
      ])
      fake.methods.count("Page.dispatchMouseEvent").should eq(4)
    ensure
      browser.try &.close
      fake.try &.close
    end
  end
end
