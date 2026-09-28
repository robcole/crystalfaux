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

The licence metadata at the pinned commit is not uniform, so each file is
attributed to the part of the repository it comes from:

- The repository root `LICENSE` is the Mozilla Public License 2.0
  (<https://mozilla.org/MPL/2.0/>).
- `pythonlib/pyproject.toml` declares `license = "MIT"` for the `camoufox`
  Python package (version 0.5.6). The pinned commit has no separate
  `pythonlib/LICENSE` file; the root `LICENSE` is the only licence text in
  the tree.

| File here | Upstream path | Licence metadata that applies |
|---|---|---|
| `properties.json` | `settings/properties.json` | root `LICENSE`: MPL-2.0 |
| `fonts.json` | `pythonlib/camoufox/fonts.json` | Python package: MIT (`pyproject.toml`); the root `LICENSE` is MPL-2.0 |

`src/crystalfaux/fingerprint/geometry.cr` and the user-agent helpers in
`src/crystalfaux/fingerprint/config.cr` and `os.cr` port logic from
`pythonlib/camoufox/fingerprints.py` and `utils.py`, which carry the same
Python package metadata (MIT) inside an MPL-2.0 repository.

This records the upstream metadata as found. It is not a legal
determination. Both JSON files are byte-for-byte copies; the upstream files
have no per-file licence headers. Copyright the Camoufox authors.

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
