require "option_parser"
require "./fetch"

module Crystalfaux
  # The `crystalfaux` command. `src/cli.cr` runs it; the library does not
  # require it.
  #
  # ```sh
  # crystalfaux fetch                     # newest supported build
  # crystalfaux fetch --version beta.31   # one build
  # crystalfaux list                      # builds for this platform
  # ```
  #
  # `fetch` prints the install directory on stdout and progress on stderr.
  class CLI
    private enum Command
      Fetch
      List
    end

    private class UsageError < Exception
    end

    @command : Command?
    @version : String?
    @allow_unsupported = false
    @help = false

    def initialize(@stdout : IO = STDOUT, @stderr : IO = STDERR, @client : Fetch::Client = Fetch::Client.new)
      @dir = Launcher::Discovery.cache_dir
    end

    # Runs the command in *args* and returns the exit status: 0 on success,
    # 1 on failure, 2 on a usage error.
    def run(args : Array(String)) : Int32
      parser = option_parser
      begin
        parser.parse(args.dup)
      rescue error : OptionParser::Exception | UsageError
        @stderr.puts "crystalfaux: #{error.message}", parser
        return 2
      end
      return help(parser) if @help

      case @command
      in Command::Fetch then fetch
      in Command::List  then list
      in Nil
        @stderr.puts parser
        2
      end
    rescue error : Crystalfaux::Error
      @stderr.puts "crystalfaux: #{error.message}"
      @stderr.puts "Use --allow-unsupported to install it anyway." if error.is_a?(UnsupportedBrowserError)
      1
    end

    private def fetch : Int32
      build = Fetch.select(Fetch.builds(@client.releases), @version, @allow_unsupported)
      @stdout.puts Fetch::Installer.new(@dir, @client, @stderr).install(build)
      0
    end

    private def list : Int32
      installer = Fetch::Installer.new(@dir, @client)
      supported = Protocol::VENDORED.supported
      Fetch.builds(@client.releases).each do |build|
        status = [build.name, supported.includes?(build.semantic_version) ? "supported" : "unsupported"]
        status << "installed" if installer.installed?(build)
        @stdout.puts status.join("  ")
      end
      0
    end

    private def help(parser : OptionParser) : Int32
      @stdout.puts parser
      0
    end

    private def option_parser : OptionParser
      OptionParser.new do |parser|
        parser.banner = "Usage: crystalfaux <fetch|list> [options]"
        parser.on("fetch", "Download and install a Camoufox build") do
          @command = Command::Fetch
          parser.banner = "Usage: crystalfaux fetch [--version <v>] [--dir <path>] [--allow-unsupported]"
          parser.on("--version VERSION", "Install this build, for example 152.0.4-beta.31 or beta.31") { |version| @version = version }
          parser.on("--allow-unsupported", "Allow a build outside the supported protocol range") { @allow_unsupported = true }
          dir_option(parser)
        end
        parser.on("list", "List the Camoufox builds for this platform") do
          @command = Command::List
          parser.banner = "Usage: crystalfaux list [--dir <path>]"
          dir_option(parser)
        end
        parser.on("-h", "--help", "Show this help") { @help = true }
        parser.unknown_args do |before, after|
          extra = before + after
          raise UsageError.new("unexpected argument: #{extra.first}") unless extra.empty?
        end
      end
    end

    private def dir_option(parser : OptionParser) : Nil
      parser.on("--dir PATH", "Install directory (default: #{@dir})") { |dir| @dir = Path[dir] }
    end
  end
end
