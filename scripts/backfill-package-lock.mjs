#!/usr/bin/env node
//
// Backfill missing `resolved` + `integrity` fields in a package-lock.json.
//
// The committed app/package-lock.json carries pinned versions but was stripped
// of the `resolved` tarball URLs and `integrity` hashes for most entries, so it
// cannot be installed offline (npm errors with ENOTCACHED, and Nix's
// fetchNpmDeps can only fetch entries that have a URL). This tool restores those
// two fields for the EXACT versions already pinned, by querying the npm registry
// for each package. It is purely additive: no version is ever changed.
//
// Run it whenever the lockfile is regenerated upstream and comes back stripped:
//   node scripts/backfill-package-lock.mjs app/package-lock.json
// then refresh the Nix npmDeps hash (see nix/package.nix).

import { readFileSync, writeFileSync } from "node:fs";

const LOCK = process.argv[2];
if (!LOCK) {
  console.error("usage: backfill-package-lock.mjs <package-lock.json>");
  process.exit(1);
}

const lock = JSON.parse(readFileSync(LOCK, "utf8"));
const packuments = new Map(); // name -> packument json (cache one fetch per package)

// Derive the npm package name from a lockfile v3 path key.
// e.g. "node_modules/a/node_modules/@scope/b" -> "@scope/b"
function nameFromPath(p) {
  const idx = p.lastIndexOf("node_modules/");
  return p.slice(idx + "node_modules/".length);
}

async function packument(name) {
  if (packuments.has(name)) return packuments.get(name);
  const res = await fetch(`https://registry.npmjs.org/${name.replace("/", "%2F")}`);
  if (!res.ok) throw new Error(`registry ${name}: HTTP ${res.status}`);
  const json = await res.json();
  packuments.set(name, json);
  return json;
}

let filled = 0;
const missing = [];
for (const [p, entry] of Object.entries(lock.packages)) {
  if (p === "") continue; // the root project itself
  if (entry.link) continue; // workspace symlinks have no registry tarball
  if (entry.resolved && entry.integrity) continue;
  if (!entry.version) {
    missing.push(`${p}: no version`);
    continue;
  }
  const name = entry.name || nameFromPath(p);
  const pj = await packument(name);
  const v = pj.versions?.[entry.version];
  if (!v) {
    missing.push(`${p}: version ${entry.version} not in registry for ${name}`);
    continue;
  }
  entry.resolved = v.dist.tarball;
  entry.integrity =
    v.dist.integrity || `sha1-${Buffer.from(v.dist.shasum, "hex").toString("base64")}`;
  filled++;
}

writeFileSync(LOCK, JSON.stringify(lock, null, 2) + "\n");
console.log(`filled ${filled} entries`);
if (missing.length) {
  console.error("UNRESOLVED:");
  for (const m of missing) console.error("  " + m);
  process.exit(1);
}
