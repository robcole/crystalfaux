# Vendored Camoufox data

These files are copied without changes from
[`daijro/camoufox`](https://github.com/daijro/camoufox) at commit
`eb5dc3bc5b917d1e6c71d9cacfecdddb55fbfc4a`, the commit of the vendored
`protocol/Protocol.js`. `VERSION.json` records the source path and the
SHA-256 of each file. A spec checks the checksums.

- `properties.json` (`settings/properties.json`): every `CAMOU_CONFIG` key
  and its value type. The installed `152.0.4-beta.31` build ships the same
  file as `Camoufox.app/Contents/Resources/properties.json`.
  `Crystalfaux::Fingerprint::Config` validates configs against it.
- `fonts.json` (`pythonlib/camoufox/fonts.json`): the font families of each
  target OS (`win`, `mac`, `lin`). `Crystalfaux::Fingerprint::Config.for`
  uses the list of the chosen OS.

The compiler embeds both files (`read_file`), so the library does not read
them at runtime.

## Licence

Camoufox is distributed under the Mozilla Public License 2.0
(<https://mozilla.org/MPL/2.0/>). These files are covered by that licence.
Copyright the Camoufox authors.

## Update the vendored copy

1. Pick the Camoufox commit of the vendored `protocol/Protocol.js`.
2. Download both files at that commit:

   ```sh
   base=https://raw.githubusercontent.com/daijro/camoufox/<commit>
   curl -fsSL -o data/camoufox/properties.json "$base/settings/properties.json"
   curl -fsSL -o data/camoufox/fonts.json "$base/pythonlib/camoufox/fonts.json"
   shasum -a 256 data/camoufox/*.json
   ```

3. Update `VERSION.json`. Check the builder in
   `src/crystalfaux/fingerprint/config.cr` against new or removed keys.
