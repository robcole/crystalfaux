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

  it "sends Browser.close, closes the pipe and removes the temp profile" do
    record = File.tempname("crystalfaux-frames")
    browser = launch(fake_options("record", FAKE_RECORD: record))

    status = browser.close

    status.success?.should be_true
    File.read(record).should eq(%({"id":-9999,"method":"Browser.close","params":{}}\0))
    Dir.exists?(browser.profile_dir).should be_false
    browser.transport.closed?.should be_true
    browser.close.should eq(status)
  ensure
    File.delete?(record) if record
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

    browser.close
    browser.exited?.should be_true
    Dir.exists?(browser.profile_dir).should be_false
  ensure
    connection.try &.close
    browser.try &.close
  end
end
