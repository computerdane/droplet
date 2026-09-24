import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";
import test from "node:test";

const source = (await readFile(new URL("./nexrad_worker.js", import.meta.url), "utf8"))
  .replace(/^import .* from "\.\/nexrad_wasm.js";$/m, "")
  .replaceAll("import.meta.url", '"https://example.test/nexrad_worker.js"');

function harness({ keys = ["a", "b", "c"], minutes = 60, failed = [], incomplete = [], unavailable = false, failFinal = [], pauseAt = null, priorKey = null, transientRefetch = null, persistentRefetch = null } = {}) {
  const messages = [], fetched = [], references = [], followed = [], priorQueries = [];
  const decoded = new Map(), fetchCount = new Map();
  const context = vm.createContext({
    URL, Date, setTimeout: (fn) => fn(), navigator: { hardwareConcurrency: 4 },
    postMessage: (msg) => messages.push(structuredClone(msg)),
    keys_since: (_site, since) => {
      assert.equal(since, minutes);
      if (unavailable) throw new Error("offline");
      return keys;
    },
    resolve_keys: (...args) => { priorQueries.push(args); return priorKey ? [priorKey] : []; },
    mockFetch: async (key) => {
      fetched.push(key);
      fetchCount.set(key, (fetchCount.get(key) || 0) + 1);
      if (key === pauseAt) return new Promise(() => {});
      if (failed.includes(key)) throw new Error("missing");
      if (key === transientRefetch && fetchCount.get(key) === 2) throw new Error("temporary outage");
      if (key === persistentRefetch && fetchCount.get(key) > 1) throw new Error("archive offline");
      return new Uint8Array([Math.max(0, keys.indexOf(key)) + 1]);
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
  return { context, messages, fetched, references, followed, priorQueries };
}

test("backfill arrives newest first, finalizes chronologically and seeds the newest final volume", async () => {
  const h = harness();
  await h.context.run("KTST");
  const volumes = h.messages.filter((m) => m.type === "volume");
  assert.deepEqual(h.fetched, ["c", "b", "a", "a", "b", "c"]);
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

test("live passes its window duration to archive selection and seeds chunk following", async () => {
  const h = harness({ minutes: 20 });
  await h.context.follow({ site: "KTST", since_minutes: 20 });
  assert.equal(h.followed.length, 1);
  assert.equal(JSON.parse(h.followed[0][8]).name, "c");
  const defaultWindow = harness();
  await defaultWindow.context.follow({ site: "KTST" });
  assert.equal(defaultWindow.followed.length, 1);
});

test("long live windows deliver every selected scan newest first then finalize in order", async () => {
  const keys = Array.from({ length: 25 }, (_, i) => `k${String(i).padStart(2, "0")}`);
  const h = harness({ keys, minutes: 600 });
  await h.context.run("KTST", 600);
  const names = h.messages.filter((m) => m.type === "volume").map((m) => m.name);
  assert.deepEqual(names, [...keys].reverse().concat(keys));
  assert.equal(h.fetched.length, 50);
});

test("a transient finalization refetch failure retries until the preview is replaced", async () => {
  const h = harness({ transientRefetch: "b" });
  await h.context.run("KTST");
  assert.deepEqual(h.fetched, ["c", "b", "a", "a", "b", "b", "c"]);
  assert.deepEqual(h.messages.filter((m) => m.type === "volume").map((m) => m.name), ["c", "b", "a", "a", "b", "c"]);
  assert.match(h.messages.find((m) => m.line?.includes("backfill refetch"))?.line, /retrying/);
  assert.equal(JSON.parse(h.context.seed().volume_json).name, "c");
});

test("persistent finalization refetch failure leaves a marked preview and starts chunk following", async () => {
  const h = harness({ persistentRefetch: "c" });
  await h.context.follow({ site: "KTST" });
  const newest = h.messages.filter((m) => m.type === "volume" && m.name === "c");
  assert.equal(newest.length, 1);
  assert.equal(JSON.parse(newest[0].volume_json).provisional, true);
  assert.equal(h.fetched.filter((key) => key === "c").length, 4, "preview plus three finalization attempts");
  assert.match(h.messages.find((m) => m.line?.includes("provisional scan unresolved"))?.line, /archive offline/);
  assert.equal(h.followed.length, 1);
  assert.equal(JSON.parse(h.followed[0][8]).name, "b", "only finalized scans seed chunks");
});

test("the first in-window scan uses an archive predecessor just outside the window", async () => {
  const first = "KTST20240501_001000_V06";
  const priorKey = "KTST20240501_000500_V06";
  const h = harness({ keys: [first], priorKey });
  await h.context.run("KTST");
  assert.deepEqual(h.references, [[first, priorKey]]);
  assert.deepEqual(h.messages.filter((m) => m.type === "volume").map((m) => m.name), [first, first]);
  assert.equal(h.fetched.includes(priorKey), true);
});

test("empty and all-failed windows do not pass an archive predecessor to chunks", async () => {
  const predecessor = "KTST20240501_000500_V06";
  const empty = harness({ keys: [], priorKey: predecessor });
  await empty.context.follow({ site: "KTST" });
  assert.equal(empty.priorQueries.length, 0);
  assert.equal(empty.context.seed(), null);
  assert.equal(empty.followed[0][8], null);

  const selected = "KTST20240501_001000_V06";
  const failed = harness({ keys: [selected], failed: [selected], priorKey: predecessor });
  await failed.context.follow({ site: "KTST" });
  assert.equal(failed.priorQueries.length, 1);
  assert.equal(failed.context.seed(), null);
  assert.equal(failed.followed[0][8], null);
});
