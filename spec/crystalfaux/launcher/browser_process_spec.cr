require "../../spec_helper"

private FAKE_BROWSER = File.expand_path("../../fixtures/fake_camoufox.sh", __DIR__)

private def fake_options(mode : String = "echo", **env) : Crystalfaux::Launcher::Options
  Crystalfaux::Launcher::Options.new(executable: FAKE_BROWSER, env: {"FAKE_MODE" => mode}.merge(env.to_h.transform_keys(&.to_s)))
end

private def launch(options : Crystalfaux::Launcher::Options, timeout : Time::Span = 5.seconds) : Crystalfaux::Launcher::BrowserProcess
  Crystalfaux::Launcher::BrowserProcess.launch(options, timeout: timeout)
end

# Returns the profile directories the launcher created in the temp dir.
private def launcher_profiles : Array(String)
  Dir.glob(File.join(Dir.tempdir, "*crystalfaux-profile*"))
end

describe Crystalfaux::Launcher::BrowserProcess do
  it "waits for the ready line, then carries Juggler frames over fds 3 and 4" do
    browser = launch(fake_options)
    connection = Crystalfaux::Juggler::Connection.new(browser.transport)

    # The fake browser echoes the request, which has the same id and no result.
    connection.call("Browser.getInfo", timeout: 2.seconds).should eq(JSON::Any.new(nil))
    browser.log_tail.should contain("Juggler listening to the pipe")
    browser.log_tail.first.should eq("args: -no-remote -headless -profile #{browser.profile_dir} -juggler-pipe -silent")
    Dir.exists?(browser.profile_dir).should be_true
  ensure
    connection.try &.close
    browser.try &.close
  end

  it "sends Browser.close through the connection, closes the pipe and removes the temp profile" do
    record = File.tempname("crystalfaux-frames")
    browser = launch(fake_options("record", FAKE_RECORD: record))
    connection = Crystalfaux::Juggler::Connection.new(browser.transport)

    status = browser.close(connection)

    status.success?.should be_true
    frames = File.read(record).split('\0', remove_empty: true).map { |frame| JSON.parse(frame) }
    frames.map(&.["method"]).should eq(["Browser.close"])
    Dir.exists?(browser.profile_dir).should be_false
    browser.transport.closed?.should be_true
    browser.close.should eq(status)
  ensure
    connection.try &.close
    File.delete?(record) if record
  end

  it "only closes the pipe when no connection is given" do
    record = File.tempname("crystalfaux-frames")
    browser = launch(fake_options("record", FAKE_RECORD: record))

    browser.close.success?.should be_true

    File.read(record).should be_empty
  ensure
    File.delete?(record) if record
  end

  it "escalates to SIGKILL when a large frame fills the pipe the browser never reads" do
    browser = launch(fake_options("stubborn"))
    connection = Crystalfaux::Juggler::Connection.new(browser.transport)
    # Far larger than a pipe buffer, so the writer blocks with the frame in
    # flight and Browser.close cannot be written.
    blocked = async { connection.call("Runtime.evaluate", {expression: "x" * 1_000_000}, timeout: 30.seconds) }
    sleep 100.milliseconds
    closing = Channel(Process::Status).new(1)
    spawn { closing.send(browser.close(connection, grace: 100.milliseconds)) }

    status = receive_within(closing, 3.seconds)

    status.exit_signal?.should eq(Signal::KILL)
    Dir.exists?(browser.profile_dir).should be_false
    receive_within(blocked).should be_a(Crystalfaux::ConnectionClosed)
  ensure
    connection.try &.close
  end

  it "closes the pipe even while a raw transport write is blocked" do
    browser = launch(fake_options("stubborn"))
    spawn do
      browser.transport.send("x" * 1_000_000)
    rescue Crystalfaux::ConnectionClosed
    end
    sleep 100.milliseconds
    closing = Channel(Process::Status).new(1)
    spawn { closing.send(browser.close(grace: 100.milliseconds)) }

    receive_within(closing, 3.seconds).exit_signal?.should eq(Signal::KILL)
    Dir.exists?(browser.profile_dir).should be_false
  end

  it "sends SIGKILL when the browser ignores pipe close and SIGTERM" do
    browser = launch(fake_options("stubborn"))

    status = browser.close(grace: 100.milliseconds)

    status.exit_signal?.should eq(Signal::KILL)
    Dir.exists?(browser.profile_dir).should be_false
  end

  it "keeps a caller-owned profile directory" do
    profile = File.tempname("crystalfaux-own-profile")
    Dir.mkdir(profile)
    options = fake_options.copy_with(profile_dir: profile)

    launch(options).close

    Dir.exists?(profile).should be_true
  ensure
    Dir.delete(profile) if profile
  end

  it "fails with the log tail when the browser exits before the ready line" do
    before = launcher_profiles

    error = expect_raises(Crystalfaux::LaunchError, /exited before it was ready/) do
      launch(fake_options("crash"))
    end

    error.message.to_s.should contain("fake crash: missing library")
    launcher_profiles.should eq(before)
  end

  it "fails and stops the browser when the ready line does not arrive in time" do
    before = launcher_profiles

    expect_raises(Crystalfaux::LaunchError, /not ready within/) do
      launch(fake_options("silent"), timeout: 200.milliseconds)
    end

    launcher_profiles.should eq(before)
  end

  it "raises the encoding error and leaves no profile when the config cannot be encoded" do
    before = launcher_profiles
    options = fake_options.copy_with(config: {"bad" => JSON::Any.new(Float64::NAN)})

    expect_raises(JSON::Error, /NaN/) { launch(options) }

    launcher_profiles.should eq(before)
  end

  it "fails before spawning when the executable does not exist" do
    options = Crystalfaux::Launcher::Options.new(executable: "/nonexistent/camoufox")

    expect_raises(Crystalfaux::LaunchError, /not an executable file/) do
      launch(options)
    end
  end
end

describe Crystalfaux::Launcher::BrowserProcess, tags: "browser" do
  it "launches Camoufox headless and answers Browser.getInfo" do
    options = Crystalfaux::Launcher::Options.new(executable: camoufox_binary)
    browser = Crystalfaux::Launcher::BrowserProcess.launch(options)
    connection = Crystalfaux::Juggler::Connection.new(browser.transport)

    connection.call("Browser.enable", {attachToDefaultContext: false, userPrefs: [] of String})
    info = connection.call("Browser.getInfo")
    info["version"].as_s.should start_with("Firefox/")

    browser.close(connection)
    browser.exited?.should be_true
    Dir.exists?(browser.profile_dir).should be_false
  ensure
    connection.try &.close
    browser.try &.close
  end
end
