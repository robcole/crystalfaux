# Committed fingerprints

These files hold one realistic macOS desktop identity for scraping trials.
Camoufox's own generator made them. crystalfaux does not need Node at
runtime: the files are plain JSON.

| File | Contents |
| --- | --- |
| `macos-desktop.json` | The fingerprint config: the object that Camoufox reads from `CAMOU_CONFIG_n`. |
| `macos-desktop.prefs.json` | The Firefox prefs that the generator sets with that config. |

Load them as follows:

```crystal
dir = Path["examples/fingerprints"]
config = Crystalfaux::Fingerprint::Config.from_json(File.read(dir / "macos-desktop.json"))
prefs = JSON.parse(File.read(dir / "macos-desktop.prefs.json")).as_h
browser = Crystalfaux::Browser.launch(config: config, prefs: prefs)
```

[`../fingerprint.cr`](../fingerprint.cr) loads them when you give it no
argument.

## The identity is static

Every browser that uses these files shows the same identity: the same
screen, WebGL renderer, fonts, voices and audio seed. Many sites can see
that. Generate a new identity for each deployment, and do not use the
committed one in production.

## How the files were made

- Package: `@camoufox/camoufox` 0.5.6 from npm, with Node 26.
- Model: fpgen `model-2/2026` from `scrapfly/fingerprint-generator`,
  archive SHA-256
  `6530b8322cdaa4ec042921c8d9a0369a0e6e0269ba636c01a7203e4a2f109936`
  (the package's `MODEL_PIN`; the same value is in
  `~/Library/Caches/camoufox/fpgen/.pinned-model`).
- Browser: Camoufox `152.0.4-beta.31`.
- Call: `launchOptions({headless: true, os: "macos", geoip: false,
  humanize: false, block_images: false, exclude_addons: ["UBO"], env: {}})`.
  [`scripts/generate-fingerprint.mjs`](../../scripts/generate-fingerprint.mjs)
  joins the `CAMOU_CONFIG_n` and `CAMOU_PREFS_n` chunks of the returned
  `env` into one JSON object each and sorts the keys.

## Changes to the generator output

The script makes these changes, so that the files hold nothing from the
machine that made them and `Fingerprint::Config` accepts them:

- **No addon paths.** `exclude_addons: ["UBO"]` keeps the absolute path of
  the default uBlock Origin addon out of the output.
- **No shell environment.** `env: {}` stops the package from copying the
  environment of the shell (home directory, user name, host name) into the
  result.
- **Fixed storage quota.** The package sets
  `dom.quotaManager.temporaryStorage.fixedLimit` to half the size of the
  disk of the machine that runs it. The script sets `244140625` instead:
  half of a 500 GB disk, in KiB.
- **Unknown keys removed.** The package adds
  `mediaDevices:microphoneLabels`, `mediaDevices:microphoneGroups`,
  `mediaDevices:webcamLabels`, `mediaDevices:webcamGroups`,
  `mediaDevices:speakerLabels` and `mediaDevices:speakerGroups`. The
  vendored `properties.json` (Camoufox `eb5dc3bc`) and the
  `152.0.4-beta.31` build do not know these keys. The package itself prints
  `Skipping unknown patch` for them, and `Fingerprint::Config` rejects them.
- **One WebGL 2 parameter removed.** `webGl2:parameters` key `37137`
  (`GL_MAX_SERVER_WAIT_TIMEOUT`) has the value `UINT64_MAX`. JavaScript
  writes it as `18446744073709552000`, which Crystal's JSON parser cannot
  read as an `Int64`. Without it, the browser reports its native value for
  that parameter.

The script sets no host screen: in headless mode the package does not read
the displays of the machine.

## Regenerate

Install the pinned package in a scratch directory outside the repository.
Do not add `package.json` or `node_modules` to the repository.

```sh
scratch=$(mktemp -d)
npm install --prefix "$scratch" @camoufox/camoufox@0.5.6
NODE_PATH="$scratch/node_modules" \
  CAMOUFOX_EXECUTABLE=/path/to/camoufox \
  node scripts/generate-fingerprint.mjs examples/fingerprints
rm -rf "$scratch"
```

The package downloads the fpgen model to `~/Library/Caches/camoufox/fpgen/`
on first use. `CAMOUFOX_EXECUTABLE` points the package at an installed
browser, so that it does not download one.

Each run makes a new random identity, so the values change. The key set
stays the same. Then run `crystal spec` to check that `Fingerprint::Config`
accepts the new files. If the package adds a key that `properties.json`
does not know, the spec fails: update the script or the vendored
`properties.json` (see [`data/camoufox/README.md`](../../data/camoufox/README.md)).
To change the package version, change `PACKAGE_VERSION` in the script and
the version in this file.
