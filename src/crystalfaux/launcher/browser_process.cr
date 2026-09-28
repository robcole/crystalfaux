require "file_utils"

module Crystalfaux::Launcher
  # A running Camoufox process with its Juggler pipe.
  #
  # ```
  # browser = Crystalfaux::Launcher::BrowserProcess.launch(options)
  # connection = Crystalfaux::Juggler::Connection.new(browser.transport)
  # connection.call("Browser.enable", {attachToDefaultContext: false, userPrefs: [] of String})
  # connection.call("Browser.getInfo")["version"] # => "Firefox/152.0.4-beta.31"
  # browser.close(connection)
  # ```
  #
  # `.launch` starts the browser through a `sh` wrapper that moves the
  # child's stdin to fd 3 and its stdout to fd 4, the Juggler pipe, and folds
  # the browser's stdout into its stderr. `.launch` returns only after the
  # browser prints `READY_LINE`, so no protocol frame is sent before then.
  #
  # Ownership:
  #
  # - `BrowserProcess` owns the child process, the three pipes, and the
  #   temporary profile directory (unless `Options#profile_dir` names one;
  #   the caller owns that directory).
  # - `#transport` wraps the fd 3 / fd 4 pipe ends. A `Juggler::Connection`
  #   built on it owns it too; closing it twice is safe.
  # - When `.launch` fails, it closes the pipes it opened, stops the process
  #   if it started, and removes the temporary profile before it raises.
  # - `#close` stops the process and releases everything, in this order:
  #   `Browser.close` through the connection, close the pipe, wait,
  #   `SIGTERM`, wait, `SIGKILL`, remove the temporary profile.
  #
  # Fibers: `.launch` starts a log reader and an exit waiter. The log reader
  # keeps the last `LOG_TAIL_LINES` lines of stderr and stops at end of
  # stream; it must keep reading, or the browser blocks on a full pipe. The
  # exit waiter reaps the process and delivers its status once.
  class BrowserProcess
    READY_LINE      = "Juggler listening to the pipe"
    DEFAULT_TIMEOUT = 30.seconds
    DEFAULT_GRACE   = 5.seconds
    LOG_TAIL_LINES  = 100

    # Moves the pipe to fds 3 and 4 and the browser's stdout to stderr, then
    # runs the browser as the same process (Playwright
    # `server/pipeTransport.ts` expects the same fd layout).
    FD_WRAPPER = %(exec 3<&0 4>&1 </dev/null >&2; exec "$0" "$@")

    # Used when `.launch` fails: the browser is not ready, so a long grace
    # period only delays the error.
    ABORT_GRACE = 500.milliseconds

    # The Juggler pipe to the browser.
    getter transport : Juggler::Transport

    # The profile directory the browser uses.
    getter profile_dir : String

    @process : Process
    @owns_profile : Bool
    @log = Deque(String).new
    @log_lock = Sync::Mutex.new
    @log_done = Channel(Nil).new
    @ready = Channel(Nil).new(1)
    @exited = Channel(Process::Status).new(1)
    @status : Process::Status?
    @closed_status : Process::Status?
    @close_lock = Sync::Mutex.new

    # Starts Camoufox and waits up to *timeout* for it to be ready.
    #
    # Raises `LaunchError` when no executable is found, when it is not an
    # executable file, when the spawn fails, and when the browser exits or
    # is not ready within *timeout*. The message ends with the log tail.
    def self.launch(options : Options, timeout : Time::Span = DEFAULT_TIMEOUT) : self
      executable = Discovery.executable(options.executable)
      unless executable
        raise LaunchError.new("Camoufox executable not found; set CRYSTALFAUX_CAMOUFOX or install Camoufox")
      end
      unless File.file?(executable) && File::Info.executable?(executable)
        raise LaunchError.new("#{executable} is not an executable file")
      end

      # Encoding can raise (for example `JSON::Error` on NaN), so it runs
      # before anything is allocated.
      environment = Launcher.environment(options)
      owned_profile = options.profile_dir
      profile_dir = owned_profile || create_temp_profile
      command = ["-c", FD_WRAPPER, executable] + Launcher.arguments(options, profile_dir)
      browser = begin
        new(command, environment, profile_dir, owns_profile: owned_profile.nil?)
      rescue ex
        FileUtils.rm_rf(profile_dir) unless owned_profile
        raise ex unless ex.is_a?(IO::Error)
        raise LaunchError.new("Could not start #{executable}: #{ex.message}", cause: ex)
      end
      browser.wait_until_ready(timeout)
      browser
    end

    private def self.create_temp_profile : String
      File.tempname("crystalfaux-profile").tap { |path| Dir.mkdir(path) }
    end

    # Creates the pipes and spawns `sh` with *command*. On failure it closes
    # every pipe it opened. On success the parent closes the child's pipe
    # ends right away, so it sees end of stream when the child exits.
    private def initialize(command : Array(String), env : Hash(String, String), @profile_dir : String,
                           *, @owns_profile : Bool)
      opened = [] of IO::FileDescriptor
      begin
        child_input, pipe_input = track(opened, IO.pipe(read_blocking: true))
        pipe_output, child_output = track(opened, IO.pipe(write_blocking: true))
        log_output, child_error = track(opened, IO.pipe(write_blocking: true))
        process = Process.new("sh", command, env: env, input: child_input, output: child_output, error: child_error)
      rescue ex
        opened.each(&.close)
        raise ex
      end
      {child_input, child_output, child_error}.each(&.close)
      @process = process
      @transport = Juggler::Transport.new(IO::Stapled.new(pipe_output, pipe_input, sync_close: true))
      spawn(name: "camoufox-log") { read_log(log_output) }
      spawn(name: "camoufox-wait") { @exited.send(@process.wait) }
    end

    # The process id of the browser. The wrapper `exec`s the browser, so it
    # keeps the wrapper's pid.
    def pid : Int64
      @process.pid
    end

    # The last `LOG_TAIL_LINES` lines of the browser's stdout and stderr.
    def log_tail : Array(String)
      @log_lock.synchronize { @log.to_a }
    end

    # Whether the browser process has exited.
    def exited? : Bool
      !wait_for_exit(Time::Span.zero).nil?
    end

    # Stops the browser and returns its exit status. Safe to call more than
    # once; later calls return the same status.
    #
    # With a *connection*, first sends `Browser.close` through it and waits
    # up to *grace* for the frame to be written; the reply is not awaited.
    # Then, whether or not that send worked, it closes the pipe and waits up
    # to *grace* for the exit. `Browser.close` alone does not end Camoufox;
    # closing the pipe does. Then it sends `SIGTERM`, waits up to *grace*
    # again, and sends `SIGKILL`. Last, it removes the temporary profile.
    def close(connection : Juggler::Connection? = nil, grace : Time::Span = DEFAULT_GRACE) : Process::Status
      @close_lock.synchronize do
        closed_status = @closed_status
        return closed_status if closed_status
        request_close(connection, grace) if connection
        @closed_status = stop(grace)
      end
    end

    # :nodoc:
    #
    # Returns when the browser prints `READY_LINE`. Otherwise stops the
    # browser and raises `LaunchError`.
    def wait_until_ready(timeout : Time::Span) : Nil
      select
      when @ready.receive
        return
      when status = @exited.receive
        @status = status
        # Let the log reader take the last lines before they are reported.
        select
        when @log_done.receive?
        when timeout(1.second)
        end
        reason = "Camoufox exited before it was ready (#{status})"
      when timeout(timeout)
        reason = "Camoufox was not ready within #{timeout}"
      end
      stop(ABORT_GRACE)
      raise LaunchError.new(with_log_tail(reason))
    end

    private def request_close(connection : Juggler::Connection, grace : Time::Span) : Nil
      connection.notify("Browser.close", timeout: grace)
    rescue ConnectionClosed | TimeoutError
      # The pipe is closed, broken or full. Closing it next ends the browser,
      # and the signals follow when it does not.
    end

    private def track(opened : Array(IO::FileDescriptor), pipe : {IO::FileDescriptor, IO::FileDescriptor}) : {IO::FileDescriptor, IO::FileDescriptor}
      opened.push(*pipe)
      pipe
    end

    private def stop(grace : Time::Span) : Process::Status
      @transport.close
      wait_for_exit(grace) ||
        signal_and_wait(Signal::TERM, grace) ||
        signal_and_wait(Signal::KILL, nil) ||
        raise "BUG: no exit status after SIGKILL"
    ensure
      FileUtils.rm_rf(@profile_dir) if @owns_profile
    end

    private def signal_and_wait(signal : Signal, span : Time::Span?) : Process::Status?
      begin
        @process.signal(signal)
      rescue RuntimeError
        # The process exited after the last check; its status is on the way.
      end
      wait_for_exit(span)
    end

    # Returns the exit status, waiting up to *span* for it, or forever when
    # *span* is `nil`. Returns `nil` when the process is still running.
    private def wait_for_exit(span : Time::Span?) : Process::Status?
      status = @status
      return status if status
      if span
        select
        when status = @exited.receive
        when timeout(span)
          return
        end
      else
        status = @exited.receive
      end
      @status = status
    end

    private def read_log(io : IO) : Nil
      ready = false
      while line = io.gets
        append_log(line)
        next if ready || !line.includes?(READY_LINE)
        ready = true
        @ready.send(nil)
      end
    rescue IO::Error
      # The pipe failed; nothing more can be read.
    ensure
      io.close
      @log_done.close
    end

    private def append_log(line : String) : Nil
      @log_lock.synchronize do
        @log << line
        @log.shift if @log.size > LOG_TAIL_LINES
      end
    end

    private def with_log_tail(reason : String) : String
      tail = log_tail
      return reason if tail.empty?
      "#{reason}. Browser log:\n#{tail.join('\n')}"
    end
  end
end
