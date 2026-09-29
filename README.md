# crystalfaux

crystalfaux is a Crystal library that launches and controls
[Camoufox](https://camoufox.com/), an anti-fingerprinting build of Firefox.
It speaks Juggler, the Firefox protocol of Playwright, directly over the
browser's pipe. You do not need Node, Python or a Playwright driver at
runtime. The API follows [Ferrum](https://github.com/rubycdp/ferrum): a
browser has contexts, a context has pages, and a page can navigate,
evaluate JavaScript, take screenshots, send input and intercept requests.

## Requirements

- Crystal 1.21 or later.
- macOS or Linux. crystalfaux does not support Windows.
- A Camoufox build in the supported range (see
  [Supported Camoufox builds](#supported-camoufox-builds)).

## Install

1. Add the dependency to your `shard.yml`. The repository is not published
   yet, so point `path:` at a local checkout:

   ```yaml
   dependencies:
     crystalfaux:
       path: ../crystalfaux
   ```

2. Run `shards install`.

3. Build the `crystalfaux` command and download Camoufox:

   ```sh
   mkdir -p bin
   crystal build lib/crystalfaux/src/cli.cr -o bin/crystalfaux
   bin/crystalfaux fetch        # the newest supported build
   bin/crystalfaux list         # the builds for this platform
   ```

   In a checkout of this repository, `shards build crystalfaux` builds the
   same command.

`crystalfaux fetch` downloads the build from the Camoufox GitHub releases,
verifies it, and installs it in the Camoufox cache
(`~/Library/Caches/camoufox` on macOS, `$XDG_CACHE_HOME/camoufox` or
`~/.cache/camoufox` on Linux). Use
`--version beta.31` for one build and `--dir PATH` for another directory.

crystalfaux finds the executable in this order:

1. `Launcher::Options#executable`,
2. the `CRYSTALFAUX_CAMOUFOX` environment variable,
3. the `CAMOUFOX_EXECUTABLE_PATH` environment variable,
4. the newest install in the Camoufox cache.

## Quick start

```crystal
require "crystalfaux"

browser = Crystalfaux::Browser.launch # headless by default
begin
  context = browser.new_context
  page = context.new_page
  page.goto("data:text/html,<title>crystalfaux</title><h1>Hello</h1>")

  page.title                                                # => "crystalfaux"
  page.evaluate("document.querySelector('h1').textContent") # => "Hello"
  page.evaluate("navigator.webdriver")                      # => false

  File.write("page.png", page.screenshot(full_page: true))
ensure
  browser.close # stops the process and removes its temporary profile
end
```

Each call has a timeout (30 seconds by default) and raises a subclass of
`Crystalfaux::Error`, for example `TimeoutError`, `NavigationError`,
`PageCrashed` or `ConnectionClosed`.

## Examples

Each example in [`examples/`](examples/) runs against a local Camoufox
build. It uses a `data:` URL or a local `HTTP::Server`, not the internet.

```sh
CRYSTALFAUX_CAMOUFOX=/path/to/camoufox crystal run examples/quick_start.cr
```

| Example | What it shows |
| --- | --- |
| [`quick_start.cr`](examples/quick_start.cr) | Launch, navigate, evaluate, type into an input, screenshot. |
| [`screenshot.cr`](examples/screenshot.cr) | Viewport PNG, full-page JPEG and a clipped WebP. |
| [`intercept.cr`](examples/intercept.cr) | Block images, answer a request without the network, add headers, read a response body. |
| [`pool.cr`](examples/pool.cr) | Run jobs on a pool of browsers that the pool replaces. |
| [`fingerprint.cr`](examples/fingerprint.cr) | Launch with a validated fingerprint config and use the main world. |

## Evaluate JavaScript

`Page#evaluate` and `Frame#evaluate` return the value as `JSON::Any`.
By default the script runs in Camoufox's isolated world. The isolated world
sees the DOM, but not the globals that the page's own scripts set.

```crystal
page.evaluate("window.appState")                # => nil
page.evaluate("window.appState", world: :main)  # => {"user" => "Ada"}
```

`world: :main` runs the script in the page's own world. It needs the config
key `allowMainWorld` set to `true` (see the next section). The page can see
and change what a main-world script uses.

## Fingerprint config and proxies

Camoufox reads its fingerprint from a config object at startup.
`Fingerprint::Config` checks each key and value type against the list of
Camoufox properties. A misspelt key raises `ConfigError`.

```crystal
config = Crystalfaux::Fingerprint::Config
  .for(
    os: :windows,
    screen: Crystalfaux::Fingerprint::Screen.new(1920, 1080),
    user_agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:152.0) Gecko/20100101 Firefox/152.0",
  )
  .merge({"allowMainWorld" => JSON::Any.new(true)})

browser = Crystalfaux::Browser.launch(config: config)
```

`Config.for` sets the keys that must agree with one another: the user agent,
the platform, the screen and window sizes, and the fonts of the OS. To use a
config from Camoufox's Python or TypeScript package, give its JSON to
`Config.from_json`.

A proxy applies to the whole browser or to one context:

```crystal
proxy = Crystalfaux::Proxy.new("proxy.example", 3128, username: "me", password: "secret")
browser = Crystalfaux::Browser.launch(proxy: proxy)
context = browser.new_context(proxy: Crystalfaux::Proxy.new("other.example", 8080))
```

Firefox preferences go in `prefs:`. A value must be a boolean, a string or
an integer from -2,147,483,648 to 2,147,483,647, as Firefox stores it.
Other values, for example `1.5`, `null` or an array, raise `PrefError`
before the browser starts:

```crystal
prefs = {
  "javascript.options.wasm"      => JSON::Any.new(false),
  "dom.webnotifications.enabled" => JSON::Any.new(false),
}
browser = Crystalfaux::Browser.launch(config: config, prefs: prefs)
```

The browser sets the prefs when it connects, through `Browser.enable`
`userPrefs`, before the first page opens. crystalfaux also sends them as
`CAMOU_PREFS_n` environment variables, which newer Camoufox builds read at
startup. On `152.0.4-beta.31`, `javascript.options.wasm`,
`dom.webnotifications.enabled`, `dom.gamepad.enabled` and
`dom.w3c_touch_events.enabled` were verified to change what a page sees.

## Network rules

```crystal
context = browser.new_context
context.block(types: [Crystalfaux::ResourceType::Image], urls: ["**/analytics/**"])
context.extra_headers = HTTP::Headers{"Accept-Language" => "en-GB"}

page = context.new_page
page.on_request do |request|
  if request.url.ends_with?("/api/user")
    request.fulfill(body: %({"name":"Ada"}), content_type: "application/json")
  end
end
page.on_response do |response|
  puts "#{response.status} #{response.url}"
end
```

- `Context#block` aborts the matching requests of every page in the
  context, before the `on_request` handlers see them.
- An `on_request` handler decides a request with `abort`, `continue` or
  `fulfill`. The page continues a request that no handler decides.
- Handlers run in their own fibers. `Response#body` waits until the
  request is complete.
- `Context#cookies`, `#set_cookies` and `#clear_cookies` read and change
  the cookies of a context.

## Browser pool

`Pool` keeps a fixed number of browsers. Each `with_page` call gets a new
context and page, and the pool closes them after the block. The pool
replaces a browser after `pages_per_browser` pages, and when it crashes or
its pipe closes.

```crystal
pool = Crystalfaux::Pool.new(size: 2, pages_per_browser: 50) do |number|
  Crystalfaux::Browser.launch(timeout: 30.seconds)
end

title = pool.with_page do |page|
  page.goto("https://example.com/")
  page.title
end

pool.close # returns after every browser has stopped
```

The launch block receives a launch number (0, 1, 2 and so on), so that each
browser can get its own config. The pool puts no deadline on the launch
block, so the block must limit its own time.

## Testing

```sh
shards install
bin/check                  # format check, Ameba and the specs
scripts/spec               # the specs only
```

The default spec run is offline. Specs tagged `browser` start the real
browser. They run only when `CRYSTALFAUX_CAMOUFOX` names a Camoufox
executable, and are pending otherwise:

```sh
CRYSTALFAUX_CAMOUFOX=/path/to/camoufox scripts/spec --tag browser
```

`bin/check` and `scripts/spec` keep the compiler cache in `.crystal-cache`
in the checkout, so runs in different checkouts do not collide.

## Supported Camoufox builds

crystalfaux uses a copy of Camoufox's Juggler schema,
[`protocol/Protocol.js`](protocol/), from the `v152.0.4-beta.31` release
commit. `protocol/VERSION.json` records the source and the supported range:

| From | To |
| --- | --- |
| `152.0.4-beta.30` | `152.0.4-beta.31` |

`Browser.launch` reads the `version.json` of the install and raises
`UnsupportedBrowserError` for a build outside this range.
`crystalfaux fetch` refuses such a build unless you give
`--allow-unsupported`.

## Unsupported and deferred

These limits are known. Some are deliberate; others are future work.

- **Platforms.** Windows is not supported. Only macOS arm64 in headless
  mode has been tested. Linux (including Xvfb and `FONTCONFIG_FILE`
  handling) has not been validated.
- **Protocols.** WebDriver BiDi is not supported; Camoufox supports
  Juggler for automation. crystalfaux does not implement the whole
  Playwright API.
- **Fingerprint generation.** crystalfaux does not port fpgen, the
  statistical model that Camoufox's packages use to generate
  fingerprints. Use `Config.for` for a small, consistent config, or load a
  config that Camoufox's packages generated.
- **Identity alignment.** crystalfaux does not align the locale, time zone,
  WebRTC IP or GeoIP data with a proxy. Set these config keys yourself.
- **Isolated world.** `Page#evaluate` uses the isolated world by default.
  The main world needs `allowMainWorld: true` in the config. In the
  isolated world, a promise that a page API returns, for example `fetch()`,
  does not settle, and the call raises `TimeoutError`. Wrap it in a promise
  that the script makes, or use `world: :main`:

  ```crystal
  page.evaluate("new Promise((resolve, reject) => fetch('/api').then(r => r.json()).then(resolve, reject))")
  ```

- **Pool launch block.** The launch block must limit its own time. It must
  not call `Pool#close`; that call raises `PoolError`. This guard covers
  only the fiber that runs the launch block. If the launch block waits for
  a `Pool#close` in another fiber, each one waits for the other until the
  launch block's own deadline.
- **Launcher environment.** `Launcher.environment` returns the full
  environment of the child process: the parent environment without
  inherited `CAMOU_CONFIG*` and `CAMOU_PREFS*` variables, plus the config,
  the prefs and `Options#env`. Give `base: {} of String => String` to get
  only the added variables.
- **Shutdown.** Camoufox does not stop after `Browser.close` alone on
  anonymous pipes. `Browser#close` then closes the pipe and signals the
  process. Socket pairs would make shutdown faster; they are deferred.

## Licence

crystalfaux is available under the MIT License (see [`LICENSE`](LICENSE)),
except for the files that come from other projects. The
[`NOTICE`](NOTICE) file lists them:

- Camoufox-derived files are under the Mozilla Public License 2.0:
  - `protocol/Protocol.js`, a copy of the Juggler schema. It keeps its MPL
    header.
  - `data/camoufox/properties.json` and `fonts.json`, copies of two data
    files. [`data/camoufox/NOTICE`](data/camoufox/NOTICE) holds their
    notice.
  - `src/crystalfaux/fingerprint/config.cr`, `geometry.cr`, `os.cr`,
    `properties.cr`, and `src/crystalfaux/fetch/build.cr` and
    `platform.cr`, which translate logic from Camoufox's Python package.
    Each file carries the MPL-2.0 notice.

  The MPL-2.0 is a file-level copyleft. If you change one of these files,
  the changed file must stay under the MPL-2.0 and its source must be
  available. The rest of crystalfaux stays MIT.
- Playwright-derived files are under the Apache License 2.0, such as the
  keyboard layout and the input rules. Each file carries a notice that
  names its source files.
