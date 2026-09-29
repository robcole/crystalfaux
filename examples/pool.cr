# Runs eight jobs on a pool of two browsers. Each browser serves three pages,
# then the pool replaces it.
#
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/pool.cr
require "../src/crystalfaux"

pool = Crystalfaux::Pool.new(size: 2, pages_per_browser: 3) do |number|
  puts "Launching browser #{number}"
  # The pool puts no deadline on this block; `Browser.launch` has its own.
  Crystalfaux::Browser.launch(timeout: 30.seconds)
end

jobs = 8
results = Channel(String).new(jobs)
jobs.times do |job|
  spawn do
    title = pool.with_page do |page|
      page.goto("data:text/html,<title>Job #{job}</title>")
      page.title
    end
    results.send("job #{job}: #{title}")
  rescue ex
    results.send("job #{job} failed: #{ex.message}")
  end
end

begin
  jobs.times { puts results.receive }
ensure
  # Waits until every browser of the pool has stopped.
  pool.close
end
