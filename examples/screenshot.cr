# Serves a long page from a local HTTP server and takes three screenshots:
# the viewport as PNG, the whole page as JPEG, and one area as WebP.
#
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/screenshot.cr
require "http/server"
require "../src/crystalfaux"

html = <<-HTML
  <title>Screenshots</title>
  <body style="margin:0">
    <div style="height:600px;background:#2e86de"></div>
    <div style="height:600px;background:#f6b93b"></div>
    <div style="height:600px;background:#38ada9"></div>
  </body>
  HTML

server = HTTP::Server.new do |context|
  context.response.content_type = "text/html"
  context.response.print html
end
address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }

out_dir = File.join(Dir.tempdir, "crystalfaux-screenshots")
Dir.mkdir_p(out_dir)

browser = Crystalfaux::Browser.launch
begin
  page = browser.new_context.new_page
  page.set_viewport_size(800, 600)
  page.goto("http://#{address}/")

  shots = {
    "viewport.png"  => page.screenshot,
    "full_page.jpg" => page.screenshot(format: :jpeg, quality: 80, full_page: true),
    "area.webp"     => page.screenshot(format: :webp, quality: 90,
      clip: Crystalfaux::Protocol::Page::Clip.new(0, 500, 400, 200)),
  }
  shots.each do |name, image|
    path = File.join(out_dir, name)
    File.write(path, image)
    puts "#{path}: #{image.size} bytes"
  end
ensure
  browser.close
  server.close
end
