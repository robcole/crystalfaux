# Entry point of the `crystalfaux` command. See `Crystalfaux::CLI`.
require "./crystalfaux"
require "./crystalfaux/cli"

exit Crystalfaux::CLI.new.run(ARGV)
