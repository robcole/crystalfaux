# Recorded Juggler frames

`probe.frames` holds all 71 frames of one real Camoufox session, in the order
the frames crossed the pipe. Each line is one frame: `> ` marks a frame that
crystalfaux sent, `< ` marks a frame that the browser sent, and the rest of
the line is the frame's JSON without changes. The offline specs in
`spec/crystalfaux/protocol/round_trip_spec.cr` decode each frame into the
typed `Crystalfaux::Protocol` structs and encode it again.

## Source

- Camoufox `152.0.4-beta.31` (install `152.0.4-beta.31-7b8d12d6`), headless,
  macOS arm64, with an empty fingerprint config.
- Recorded on 2026-09-28 by `spec/crystalfaux/protocol/recording_spec.cr`.

The session follows the probe in `plans/landscape.md` Appendix A:
`Browser.enable`, `Browser.getInfo`, `Browser.createBrowserContext`,
`Browser.newPage` with `Browser.attachedToTarget`, `Page.frameAttached`,
`Page.navigate` to a `data:` URL until its `load` event, and
`Runtime.evaluate`. It then adds evaluations of `null` and `undefined`
(`{"value":null}` versus no `value`), evaluations that throw an `Error` and
a number, `Runtime.callFunction` with number and `null` arguments, a page load from a local `HTTP::Server` (network events,
`Network.getResponseBody`, `Browser.getCookies`), `Page.setViewportSize`,
a 2x2 `Page.screenshot`, `Page.dispatchMouseEvent`, `Page.close`,
`Browser.removeBrowserContext` and `Browser.close`.

Nothing is redacted. Ids, the local server port and timings differ in each
recording; the specs do not depend on them.

`elements.frames` holds a second, shorter session of the same build: a
`data:` page with a button below the fold, a `Runtime.callFunction` that
returns an array handle, `Runtime.getObjectProperties` for its element
handles, `Page.scrollIntoViewIfNeeded`, `Page.getContentQuads` and
`Runtime.disposeObject`. It was recorded on 2026-09-28 by the same spec and
does not end with `Browser.close`.

## Record again

```sh
CRYSTALFAUX_CAMOUFOX=/path/to/camoufox CRYSTALFAUX_RECORD_FIXTURES=1 \
  crystal spec spec/crystalfaux/protocol/recording_spec.cr --tag browser
```

Without `CRYSTALFAUX_RECORD_FIXTURES`, the spec runs the same sessions and
checks the round trip of the live frames, but does not write the files.
