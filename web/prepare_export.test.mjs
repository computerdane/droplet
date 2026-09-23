import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { prepare } from "./prepare_export.mjs";

function temporary(t) {
  const root = mkdtempSync(join(tmpdir(), "droplet-export-test-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

test("cache, offline fallback and manifest stay inside a deployment scope", (t) => {
  const root = temporary(t);
  const worker = join(root, "index.service.worker.js");
  writeFileSync(worker, "const CACHE_PREFIX = 'Droplet-sw-cache-';\nreturn caches.match(OFFLINE_URL);\n");
  const manifest = join(root, "index.manifest.json");
  writeFileSync(manifest, '{"name":"Droplet","icons":[]}');
  prepare(root);
  assert.match(readFileSync(worker, "utf8"), /encodeURIComponent\(self.registration.scope\)/);
  assert.match(readFileSync(worker, "utf8"), /return cache.match\(OFFLINE_URL\)/);
  assert.deepEqual(JSON.parse(readFileSync(manifest, "utf8")), {
    name: "Droplet", icons: [], id: "./", scope: "./", start_url: "./index.html",
  });
});

test("changed upstream worker fails without writing", (t) => {
  const root = temporary(t);
  const worker = join(root, "index.service.worker.js");
  for (const source of ["changed upstream", "const CACHE_PREFIX = 'Droplet-sw-cache-';\n"]) {
    writeFileSync(worker, source);
    assert.throws(() => prepare(root), /unsupported Godot service worker/);
    assert.equal(readFileSync(worker, "utf8"), source);
  }
});
