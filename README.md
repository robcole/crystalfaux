# crystalfaux

crystalfaux is a browser automation library for
[Crystal](https://crystal-lang.org/) that drives
[Camoufox](https://camoufox.com/), an anti-fingerprinting build of Firefox.

## Purpose

Tools like [Ferrum](https://github.com/rubycdp/ferrum) (Ruby) and
[Playwright](https://playwright.dev/) give developers a high-level API for
launching, controlling, and inspecting a browser. Camoufox is usually driven
through the Playwright Python bindings.

crystalfaux gives Crystal projects a similar API that drives Camoufox
directly, without Node or Python at runtime.

## Scope

- **Protocol**: a Crystal client for Juggler, the Firefox protocol of
  Playwright, over the browser's pipe.
- **Launching and configuration**: find or fetch the Camoufox binary, pass
  fingerprint and config options, and manage the browser process.
- **API**: browsers, contexts, pages, navigation, selectors, input, network
  interception, screenshots, and JavaScript evaluation, in idiomatic Crystal.
- **Concurrency**: protocol events and request/response flows on Crystal
  fibers and channels.

## Status

Pre-release and in early development. The library is not usable yet, and
the API can change.
