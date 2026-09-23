import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const source = (await readFile(new URL("./nexrad_worker.js", import.meta.url), "utf8"))
  .replace(/^import .* from "\.\/nexrad_wasm.js";$/m, "")
  .replaceAll("import.meta.url", '"https://example.test/nexrad_worker.js"');

function harness({ keys = ["a", "b", "c"], failed = [], incomplete = [], unavailable = false } = {}) {
  const messages = [], fetched = [], references = [];
  const context = vm.createContext({
    URL, navigator: { hardwareConcurrency: 4 },
    postMessage: (msg) => messages.push(structuredClone(msg)),
    recent_keys: (_site, count) => {
      assert.equal(count, 11);
      if (unavailable) throw new Error("offline");
      return keys;
    },
    mockFetch: async (key) => {
      fetched.push(key);
      if (failed.includes(key)) throw new Error("missing");
      return new Uint8Array([keys.indexOf(key) + 1]);
    },
    decode: (bytes, key) => ({
      name: key,
      volume_json: JSON.stringify({ name: key, complete: !incomplete.includes(key) }),
      files: new Map([["s00_DVEL.bin", new Uint8Array(bytes)]]),
    }),
    redealias: (meta, files, priorMeta, priorFiles) => {
      references.push([JSON.parse(meta).name, JSON.parse(priorMeta).name]);
      return { volume_json: meta, files: new Map([["s00_DVEL.bin", new Uint8Array([
        files.get("s00_DVEL.bin")[0] + priorFiles.get("s00_DVEL.bin")[0],
      ])]]) };
    },
  });
  vm.runInContext(source + "\nfetchRaw = mockFetch; globalThis.run = backfill; globalThis.seed = () => prior;", context);
  return { context, messages, fetched, references };
}

test("backfill arrives newest first, finalizes chronologically and seeds the newest final volume", async () => {
  const h = harness();
  await h.context.run("KTST");
  const volumes = h.messages.filter((m) => m.type === "volume");
  assert.deepEqual(h.fetched, ["c", "b", "a"]);
  assert.deepEqual(volumes.map((v) => v.name), ["c", "b", "a", "a", "b", "c"]);
  assert.deepEqual(volumes.map((v) => new Uint8Array(v.buffers[0])[0]), [3, 2, 1, 1, 3, 6]);
  assert.deepEqual(h.references, [["b", "a"], ["c", "b"]]);
  assert.equal(JSON.parse(h.context.seed().volume_json).name, "c");
  assert.equal(h.context.seed().files.get("s00_DVEL.bin")[0], 6);
});

test("failed downloads are skipped and finalization keeps the latest successful complete seed", async () => {
  const h = harness({ failed: ["b"], incomplete: ["c"] });
  await h.context.run("KTST");
  assert.deepEqual(h.messages.filter((m) => m.type === "volume").map((v) => v.name), ["c", "a", "a", "c"]);
  assert.equal(JSON.parse(h.context.seed().volume_json).name, "a");
  assert.deepEqual(h.references, [["c", "a"]]);
});

test("an unavailable archive leaves live following unseeded without throwing", async () => {
  const h = harness({ unavailable: true });
  await h.context.run("KTST");
  assert.equal(h.context.seed(), null);
  assert.match(h.messages[0].line, /backfill unavailable: offline/);
  assert.equal(h.fetched.length, 0);
});
