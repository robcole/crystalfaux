# Changes network traffic: blocks images, answers an API call without the
# network, adds a header, and reads a response body.
#
#   CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/intercept.cr
require "http/server"
require "../src/crystalfaux"

server = HTTP::Server.new do |context|
  request = context.request
  case request.path
  when "/"
    context.response.content_type = "text/html"
    context.response.print %(<title>Intercept</title><img src="/logo.png">)
  when "/echo"
    context.response.content_type = "text/plain"
    context.response.print "X-Example: #{request.headers["X-Example"]?}"
  else
    context.response.status = :not_found
  end
end
address = server.bind_tcp("127.0.0.1", 0)
spawn { server.listen }

browser = Crystalfaux::Browser.launch
begin
  context = browser.new_context
  # Rules apply to every page of the context, before `on_request` handlers.
  context.block(types: [Crystalfaux::ResourceType::Image])
  context.extra_headers = HTTP::Headers{"X-Example" => "crystalfaux"}

  page = context.new_page

  # Answer /api/user without a server. Requests that no handler decides go
  # on to the network.
  page.on_request do |request|
    if request.url.ends_with?("/api/user")
      request.fulfill(body: %({"name":"Ada"}), content_type: "application/json")
    end
  end

  # Handlers run in their own fibers; send what they see to a channel.
  responses = Channel(String).new(16)
  page.on_response do |response|
    line = "#{response.status} #{response.url}"
    line += " -> #{response.text.inspect}" if response.url.ends_with?("/echo")
    responses.send(line)
  end

  page.goto("http://#{address}/")
  # In the isolated world a promise from a page API, such as `fetch`, does
  # not settle. Wrap it in a promise that the script makes itself.
  fetch_json = "new Promise((resolve, reject) => fetch('/api/user').then(r => r.json()).then(resolve, reject))"
  fetch_text = "new Promise((resolve, reject) => fetch('/echo').then(r => r.text()).then(resolve, reject))"
  puts "API: #{page.evaluate(fetch_json).to_json}"
  puts "Echo: #{page.evaluate(fetch_text)}"
  puts "Image loaded: #{page.evaluate("document.querySelector('img').naturalWidth > 0")}"

  # The document, the fulfilled API call and /echo; the image was blocked.
  3.times do
    select
    when line = responses.receive
      puts "Response: #{line}"
    when timeout(5.seconds)
      break
    end
  end
ensure
  browser.close
  server.close
end
