# Slices of the recorded probe session in
# `spec/fixtures/juggler/probe.frames`, as the browser sent them. The
# browser-object specs replay them through `ScriptedBrowser`.
module ProbeScript
  FRAMES = JugglerFrame.load(File.expand_path("../fixtures/juggler/probe.frames", __DIR__))

  SESSION_ID = "7731b37c-b4d2-48e2-afdc-ff9b168a1eb9"
  CONTEXT_ID = "46bd2967-cef3-4ea8-afc6-2cd57d57c367"
  TARGET_ID  = "f5ba3481-4fda-4800-95ca-1c615c9f8cb7"
  FRAME_ID   = "mainframe-10"
  DATA_URL   = "data:text/html,<!DOCTYPE html><title>crystalfaux</title>"

  # The recorded reply to the first request that matches the block.
  def self.reply_to(& : JSON::Any -> Bool) : JSON::Any
    FRAMES[reply_index { |request| yield request }].json
  end

  def self.reply_to(method : String) : JSON::Any
    reply_to(&.["method"].==(method))
  end

  # What the browser sent for `Browser.newPage`: the attach event, the reply,
  # and the new page's frame, execution-context and lifecycle events up to
  # `Page.ready` and the first `load`. The probe sent `Page.navigate` in the
  # middle of them; the slice leaves that request out and ends before its
  # reply.
  def self.new_page : Array(JSON::Any)
    start = FRAMES.index! { |frame| !frame.sent && frame.json["method"]? == "Browser.attachedToTarget" }
    finish = reply_index(&.["method"].==("Page.navigate"))
    FRAMES[start...finish].reject(&.sent).map(&.json)
  end

  # What the browser sent for the first `Page.navigate`: the reply, then the
  # navigation events up to the `load` of the new document.
  def self.navigate : Array(JSON::Any)
    start = reply_index(&.["method"].==("Page.navigate"))
    FRAMES[start..].take_while { |frame| !frame.sent }.map(&.json)
  end

  private def self.reply_index(& : JSON::Any -> Bool) : Int32
    request = FRAMES.find { |frame| frame.sent && yield frame.json } || raise "no matching recorded request"
    id = request.json["id"]
    FRAMES.index! { |frame| !frame.sent && frame.json["id"]? == id }
  end
end
