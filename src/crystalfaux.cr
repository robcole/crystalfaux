# Launches and drives Camoufox over Playwright's Juggler protocol.
module Crystalfaux
  VERSION = "0.1.0"
end

require "./crystalfaux/errors"
require "./crystalfaux/juggler/*"
require "./crystalfaux/launcher"
require "./crystalfaux/launcher/*"
require "./crystalfaux/protocol"
require "./crystalfaux/protocol/*"
require "./crystalfaux/frame"
require "./crystalfaux/page"
require "./crystalfaux/page/*"
require "./crystalfaux/context"
require "./crystalfaux/browser"
require "./crystalfaux/browser/*"
