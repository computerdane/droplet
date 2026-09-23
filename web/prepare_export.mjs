#!/usr/bin/env node
// Give each Pages deployment its own PWA identity and service-worker cache.
// Fail closed if Godot changes its generated worker contract.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

export function prepare(root) {
  const worker = join(root, "index.service.worker.js");
  let source = readFileSync(worker, "utf8");
  const replacements = new Map([
    ["const CACHE_PREFIX = 'Droplet-sw-cache-';",
      "const CACHE_PREFIX = 'Droplet-sw-cache-' + encodeURIComponent(self.registration.scope) + '-';"],
    ["return caches.match(OFFLINE_URL);", "return cache.match(OFFLINE_URL);"],
  ]);
  for (const [before, after] of replacements) {
    if (source.split(before).length !== 2) {
      throw new Error(`unsupported Godot service worker: expected one ${JSON.stringify(before)}`);
    }
    source = source.replace(before, after);
  }
  const manifestPath = join(root, "index.manifest.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  Object.assign(manifest, { id: "./", scope: "./", start_url: "./index.html" });
  writeFileSync(worker, source);
  writeFileSync(manifestPath, JSON.stringify(manifest) + "\n");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) prepare(process.argv[2]);
