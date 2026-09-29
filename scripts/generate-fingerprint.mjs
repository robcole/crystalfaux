// Generates the committed macOS desktop fingerprint in examples/fingerprints/
// with Camoufox's own generator. Node runs only here, never at crystalfaux
// runtime. See examples/fingerprints/README.md for how to run it.
//
//   npm install --prefix "$SCRATCH" @camoufox/camoufox@0.5.6
//   NODE_PATH="$SCRATCH/node_modules" CAMOUFOX_EXECUTABLE=/path/to/camoufox \
//     node scripts/generate-fingerprint.mjs examples/fingerprints
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

// Keep in step with examples/fingerprints/README.md.
const PACKAGE_VERSION = "0.5.6";

const scratch = process.env.NODE_PATH;
if (!scratch) throw new Error("Set NODE_PATH to the node_modules of a scratch install");
const require = createRequire(join(resolve(scratch), "noop.js"));
const packageJson = require("@camoufox/camoufox/package.json");
if (packageJson.version !== PACKAGE_VERSION) {
  throw new Error(`Expected @camoufox/camoufox ${PACKAGE_VERSION}, found ${packageJson.version}`);
}
const { launchOptions } = await import(require.resolve("@camoufox/camoufox"));

const outDir = process.argv[2] ?? "examples/fingerprints";
const options = await launchOptions({
  headless: true,
  os: "macos",
  geoip: false,
  humanize: false,
  block_images: false,
  // No default addons: their entries are absolute paths on this machine.
  exclude_addons: ["UBO"],
  executable_path: process.env.CAMOUFOX_EXECUTABLE,
  // An empty base environment, so that the result holds only Camoufox's own
  // variables and nothing from the shell of the person who runs this.
  env: {},
});

// Joins the chunked CAMOU_<name>_1..N variables back into one JSON object.
function joinChunks(env, name) {
  const pattern = new RegExp(`^CAMOU_${name}_(\\d+)$`);
  const chunks = Object.entries(env)
    .map(([key, value]) => [key.match(pattern), value])
    .filter(([match]) => match)
    .sort(([a], [b]) => Number(a[1]) - Number(b[1]))
    .map(([, value]) => String(value));
  return chunks.length === 0 ? null : JSON.parse(chunks.join(""));
}

const config = joinChunks(options.env, "CONFIG");
if (!config) throw new Error("launchOptions returned no CAMOU_CONFIG_n variables");
const prefs = joinChunks(options.env, "PREFS") ?? options.firefoxUserPrefs ?? {};

// Keys that the vendored properties.json (Camoufox eb5dc3bc) and the
// 152.0.4-beta.31 build do not know. The package itself prints
// "Skipping unknown patch" for them, and Fingerprint::Config rejects them.
const UNKNOWN_KEYS = [
  "mediaDevices:microphoneLabels",
  "mediaDevices:microphoneGroups",
  "mediaDevices:webcamLabels",
  "mediaDevices:webcamGroups",
  "mediaDevices:speakerLabels",
  "mediaDevices:speakerGroups",
];
for (const key of UNKNOWN_KEYS) delete config[key];

// GL_MAX_SERVER_WAIT_TIMEOUT is UINT64_MAX. JavaScript writes it as
// 18446744073709552000, which Crystal's JSON parser cannot read as an Int64.
// Without it, the browser reports its native value.
delete config["webGl2:parameters"]?.["37137"];

// The package sets this pref to half the size of the disk of the machine that
// runs it. Use a fixed value instead: half of a 500 GB disk, in KiB.
const QUOTA_PREF = "dom.quotaManager.temporaryStorage.fixedLimit";
if (QUOTA_PREF in prefs) prefs[QUOTA_PREF] = 244140625;

const sorted = (object) => Object.fromEntries(Object.entries(object).sort(([a], [b]) => a.localeCompare(b)));
writeFileSync(join(outDir, "macos-desktop.json"), `${JSON.stringify(sorted(config), null, 2)}\n`);
writeFileSync(join(outDir, "macos-desktop.prefs.json"), `${JSON.stringify(sorted(prefs), null, 2)}\n`);
console.log(`Wrote ${Object.keys(config).length} config keys and ${Object.keys(prefs).length} prefs to ${outDir}`);
