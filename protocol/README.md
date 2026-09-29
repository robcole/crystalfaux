# Vendored Juggler protocol

`Protocol.js` is Camoufox's Juggler schema, copied without changes from
`daijro/camoufox` `additions/juggler/protocol/Protocol.js` (MPL-2.0).
`VERSION.json` records where it came from:

- `commit`: the Camoufox commit. It is the `v152.0.4-beta.31` release
  commit; its `upstream.sh` pins `version=152.0.4` and `release=beta.31`.
- `camoufox_version` and `camoufox_build`: the build the file came from.
- `fetched`: the date the file was downloaded.
- `sha256`: the SHA-256 of `Protocol.js`. A spec checks it.
- `supported`: the builds that `Crystalfaux::Protocol.check_install`
  accepts. The file is byte-identical in `v152.0.4-beta.30` (commit
  `df35ae79d2b62bb652e04325dc23c993608cbc65`), so that build is the minimum.

The typed structs in `src/crystalfaux/protocol/` are written by hand from
this file.

## Update the vendored copy

1. Find the release commit on `daijro/camoufox` whose `upstream.sh` pins the
   new build.
2. Download the file at that commit:

   ```sh
   curl -fsSL -o protocol/Protocol.js \
     https://raw.githubusercontent.com/daijro/camoufox/<commit>/additions/juggler/protocol/Protocol.js
   shasum -a 256 protocol/Protocol.js
   ```

3. Update `VERSION.json`, compare the diff of `Protocol.js` with the structs,
   and record the fixtures again (see `spec/fixtures/juggler/README.md`).
