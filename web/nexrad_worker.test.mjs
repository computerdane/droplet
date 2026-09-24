import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const source = (await readFile(new URL("./nexrad_worker.js", import.meta.url), "utf8"))
  .replace(/^import .* from "\.\/nexrad_wasm.js";$/m, "")
  .replaceAll("import.meta.url", '"https://example.test/nexrad_worker.js"');

function harness({ keys = ["a", "b", "c"], minutes = 60, failed = [], incomplete = [], unavailable = false, failFinal = [], pauseAt = null } = {}) {
  const messages = [], fetched = [], references = [], followed = [];
  const decoded = new Map();
  const context = vm.createContext({
    URL, navigator: { hardwareConcurrency: 4 },
    postMessage: (msg) => messages.push(structuredClone(msg)),
    keys_since: (_site, since) => {
      assert.equal(since, minutes);
      if (unavailable) throw new Error("offline");
      return keys;
    },
    mockFetch: async (key) => {
      fetched.push(key);
      if (key === pauseAt) return new Promise(() => {});
      if (failed.includes(key)) throw new Error("missing");
      return new Uint8Array([keys.indexOf(key) + 1]);
    },
    decode: (bytes, key) => {
      decoded.set(key, (decoded.get(key) || 0) + 1);
      if (decoded.get(key) > 1 && failFinal.includes(key)) throw new Error("finalization failed");
      return {
      name: key,
      volume_json: JSON.stringify({ name: key, complete: !incomplete.includes(key) }),
      files: new Map([["s00_DVEL.bin", new Uint8Array(bytes)]]),
      };
    },
    live: (...args) => { followed.push(args); },
    redealias: (meta, files, priorMeta, priorFiles) => {
      references.push([JSON.parse(meta).name, JSON.parse(priorMeta).name]);
      return { volume_json: meta, files: new Map([["s00_DVEL.bin", new Uint8Array([
        files.get("s00_DVEL.bin")[0] + priorFiles.get("s00_DVEL.bin")[0],
      ])]]) };
    },
  });
  vm.runInContext(source + "\nfetchRaw = mockFetch; globalThis.run = backfill; globalThis.seed = () => prior; globalThis.follow = follow;", context);
  return { context, messages, fetched, references, followed };
}

test("backfill arrives newest first, finalizes chronologically and seeds the newest final volume", async () => {
  const h = harness();
  await h.context.run("KTST");
  const volumes = h.messages.filter((m) => m.type === "volume");
  assert.deepEqual(h.fetched, ["c", "b", "a"]);
  assert.deepEqual(volumes.map((v) => v.name), ["c", "b", "a", "a", "b", "c"]);
  assert.deepEqual(volumes.map((v) => JSON.parse(v.volume_json).provisional === true), [true, true, true, false, false, false]);
  assert.deepEqual(volumes.map((v) => new Uint8Array(v.buffers[0])[0]), [3, 2, 1, 1, 3, 6]);
  assert.deepEqual(h.references, [["b", "a"], ["c", "b"]]);
  assert.equal(JSON.parse(h.context.seed().volume_json).name, "c");
  assert.equal(h.context.seed().files.get("s00_DVEL.bin")[0], 6);
});

test("failed finalization leaves a durable provisional marker and never seeds live", async () => {
  const h = harness({ failFinal: ["c"] });
  await h.context.run("KTST");
  const newest = h.messages.filter((m) => m.type === "volume" && m.name === "c");
  assert.equal(newest.length, 1);
  assert.equal(JSON.parse(newest[0].volume_json).provisional, true);
  assert.equal(JSON.parse(h.context.seed().volume_json).name, "b");
});

test("stopping a worker after preview delivery cannot leave a canonical-looking frame", async () => {
  const h = harness({ pauseAt: "b" });
  void h.context.run("KTST");
  await new Promise(setImmediate); // c published; next raw request is pending when worker is terminated
  const volumes = h.messages.filter((m) => m.type === "volume");
  assert.equal(volumes.length, 1);
  assert.equal(JSON.parse(volumes[0].volume_json).provisional, true);
  assert.equal(h.context.seed(), null);
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

test("live backfills the app's live window: since_minutes reaches keys_since", async () => {
  const h = harness({ minutes: 20 });
  await h.context.follow({ site: "KTST", since_minutes: 20 });
  assert.deepEqual(h.fetched, ["c", "b", "a"]);
  assert.equal(h.followed.length, 1, "then follows the chunks bucket");
  assert.equal(JSON.parse(h.followed[0][8]).name, "c", "seeded by the backfill's newest final volume");
  const d = harness();
  await d.context.follow({ site: "KTST" });
  assert.equal(d.followed.length, 1, "60 min when the request does not say");
});

test("a long live window backfills only the newest BACKFILL_MAX (10) scans the page can keep", async () => {
  const keys = Array.from({ length: 25 }, (_, i) => `k${String(i).padStart(2, "0")}`);
  const h = harness({ keys, minutes: 600 });
  await h.context.run("KTST", 600);
  assert.equal(h.fetched.length, 10);
  assert.equal(h.fetched[0], "k24", "newest first");
  assert.equal(h.fetched.at(-1), "k15");
  assert.match(h.messages[0].line, /the newest 10 of 25 scans in the last 600 min/);
});
