# Plays Camoufox for the browser-object specs over an in-process pipe. It
# answers each request with the frames of the script for its method, and
# records the method of every request in order.
#
# A script returns the frames to send. A frame with an `id` is the reply: its
# id is replaced by the id of the live request. A method with no script gets
# an empty reply. The default scripts replay `ProbeScript`.
#
# One fiber serves requests until the pipe closes.
class ScriptedBrowser
  alias Script = JSON::Any -> Array(JSON::Any)

  getter peer : JugglerPeer
  @scripts = {} of String => Script
  @methods = [] of String
  @requests = Channel(JSON::Any).new(256)
  @lock = Sync::Mutex.new

  def initialize(@peer : JugglerPeer)
    on("Browser.getInfo") { [ProbeScript.reply_to("Browser.getInfo")] }
    on("Browser.createBrowserContext") { [ProbeScript.reply_to("Browser.createBrowserContext")] }
    on("Browser.newPage") { ProbeScript.new_page }
    on("Page.navigate") { ProbeScript.navigate }
    spawn(name: "scripted-browser") { serve }
  end

  # Replaces the script for *method*.
  def on(method : String, &script : Script) : Nil
    @lock.synchronize { @scripts[method] = script }
  end

  # The methods of the requests received so far, in order.
  def methods : Array(String)
    @lock.synchronize { @methods.dup }
  end

  # Returns the next received request for *method*, skipping others.
  def request(method : String, timeout : Time::Span = 1.second) : JSON::Any
    deadline = Time.instant + timeout
    loop do
      request = receive_within(@requests, {deadline - Time.instant, Time::Span.zero}.max)
      return request if request["method"] == method
    end
  end

  # Sends one event to *session_id*, or to the root session when `nil`.
  def event(method : String, params, session_id : String? = ProbeScript::SESSION_ID) : Nil
    @peer.event(method, params, session_id)
  end

  def close : Nil
    @peer.close
  end

  private def serve : Nil
    while request = @peer.receive?
      method = request["method"].as_s
      script = @lock.synchronize do
        @methods << method
        @scripts[method]?
      end
      @requests.send(request)
      frames = script.try(&.call(request)) || [JSON.parse(%({"id":0}))]
      frames.each { |frame| @peer.raw(with_id(frame, request["id"]).to_json) }
    end
  rescue Crystalfaux::ConnectionClosed
    # The client closed the pipe.
  end

  private def with_id(frame : JSON::Any, id : JSON::Any) : JSON::Any
    hash = frame.as_h
    return frame unless hash.has_key?("id")
    JSON::Any.new(hash.merge({"id" => id}))
  end
end

class Crystalfaux::Page
  # Returns once every event the fake browser sent before this call has been
  # handled: the reader handles frames in order, so a reply comes after them.
  # Works on a closed page too; it bypasses the page's own checks.
  def wait_for_events_for_spec : Nil
    @connection.call("Spec.sync", nil, @session_id)
  end
end

# Returns a frame that JSON-encodes *message*.
def json_frame(message) : JSON::Any
  JSON.parse(message.to_json)
end

# Connects a `Crystalfaux::Browser` to a `ScriptedBrowser` that replays the
# recorded probe.
def scripted_browser : {Crystalfaux::Browser, ScriptedBrowser}
  connection, peer = connected_pair
  fake = ScriptedBrowser.new(peer)
  {Crystalfaux::Browser.connect(connection), fake}
end

# Opens a page in a new context of *browser* and navigates it to the
# recorded data URL.
def loaded_page(browser : Crystalfaux::Browser) : Crystalfaux::Page
  page = browser.new_context.new_page
  page.goto(ProbeScript::DATA_URL)
  page
end
