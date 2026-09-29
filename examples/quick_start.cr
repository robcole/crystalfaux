# Launches Camoufox, opens a page, reads it, and takes a screenshot.
#
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/quick_start.cr
require "../src/crystalfaux"

html = <<-HTML
  <title>crystalfaux</title>
  <h1>Hello from Camoufox</h1>
  <input id="name">
  HTML

browser = Crystalfaux::Browser.launch
begin
  puts "Browser: #{browser.version}"

  context = browser.new_context
  page = context.new_page
  page.goto("data:text/html,#{URI.encode_path(html)}")

  puts "Title: #{page.title}"
  puts "Heading: #{page.evaluate("document.querySelector('h1').textContent")}"
  puts "navigator.webdriver: #{page.evaluate("navigator.webdriver")}"

  # Type into the input. Click it first to give it the focus.
  # The script returns whole numbers, which JSON gives back as integers.
  point = page.evaluate(<<-JS).as_a.map(&.as_i.to_f)
    (() => {
      const box = document.querySelector('#name').getBoundingClientRect();
      return [Math.round(box.x + 5), Math.round(box.y + 5)];
    })()
    JS
  page.mouse.click(point[0], point[1])
  page.keyboard.type("Crystal")
  puts "Input value: #{page.evaluate("document.querySelector('#name').value")}"

  path = File.join(Dir.tempdir, "crystalfaux-quick-start.png")
  File.write(path, page.screenshot)
  puts "Screenshot: #{path} (#{File.size(path)} bytes)"

  context.close
ensure
  browser.close
end
