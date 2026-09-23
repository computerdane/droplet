// The web build's stand-in for the `nexrad` CLI (scripts/fetcher.gd starts one module worker per
// job and terminates it to stop, as it kills a process on the desktop). Posted one JSON request:
//   {"cmd": "update", "site": "KTLX", "at": "", "from": "", "to": ""}   (ISO times or "")
//   {"cmd": "live", "site": "KTLX", "interval": 5, "hint": {"volume": 417, "time_ms": ...}}
// Answers with {type: "line", line} (the CLI's output lines, "[i/n] file" progress included),
// {type: "volume", name, volume_json, names, buffers} (sweep file names and their float16
// ArrayBuffers, transferred), and finally {type: "done"} or {type: "error", message}. Live also
// sends {type: "ring", volume, time_ms} as each volume begins: where the chunks ring was, which
// the page keeps (localStorage) and passes back as `hint` so the next visit skips the search.
//
// An update of several volumes fans the decoding out to a pool of nested workers running this
// same script ({"cmd": "decode", key, index} -> {type: "decoded", index, ...volume}) and still
// hands the volumes on in key order, so progress and "jump to the last one" read as they do
// from the CLI. Terminating the job's worker terminates its pool with it. Decoded apart, the
// volumes lack the CLI's temporal dealiasing reference (the previous volume); in key order each
// is dealiased again against the one before (redealias(), a no-op unless its DVEL changes).
//
// Both Unidata buckets allow anonymous CORS reads and listings. Listings go through synchronous
// XHR, which workers may use, because the key selection and live loop in nexrad-wasm are blocking
// Rust. Raw archive files are immutable and kept in the Cache API (the newest RAW_CACHE_FILES),
// so revisiting an event costs only the decode.
import init, { decode, live, redealias, resolve_keys } from "./nexrad_wasm.js";

const ARCHIVE = "https://unidata-nexrad-level2.s3.amazonaws.com";
const CHUNKS = "https://unidata-nexrad-level2-chunks.s3.amazonaws.com";
const RAW_CACHE = "droplet-raw-v1";
const RAW_CACHE_FILES = 300; // 7 to 11 MB each
// Decoders per update job; Godot's renderer and its worker threads need cores too.
const POOL_SIZE = Math.max(1, Math.min(4, (navigator.hardwareConcurrency || 4) - 2));

const line = (text) => postMessage({ type: "line", line: text });
const fileName = (key) => key.split("/").pop();

function getSync(url, binary) {
  const x = new XMLHttpRequest();
  x.open("GET", url, false);
  if (binary) x.responseType = "arraybuffer";
  x.send();
  if (x.status !== 200) throw new Error(`GET ${url}: HTTP ${x.status}`);
  return binary ? new Uint8Array(x.response) : x.responseText;
}

const bucket = (base) => ({
  list: (prefix) => getSync(`${base}/?list-type=2&max-keys=1000&prefix=${encodeURIComponent(prefix)}`, false),
  get: (key) => getSync(`${base}/${key}`, true),
});

// postMessage arguments for a decoded volume (decode()'s {name, volume_json, files: Map}).
function volumeMessage(vol, extra = {}) {
  const names = [...vol.files.keys()];
  const buffers = names.map((n) => vol.files.get(n).buffer);
  return [{ type: "volume", name: vol.name, volume_json: vol.volume_json, names, buffers, ...extra }, buffers];
}

const postVolume = (vol) => postMessage(...volumeMessage(vol));

// The volume an update passed on last, as redealias() takes it: volume.json and DVEL files.
let prior = null;

// A "volume" message dealiased again against `prior` (sweep files replaced or added in place);
// it then becomes the prior of the next one.
function withPrior(msg) {
  if (prior) {
    const files = new Map(msg.names.map((n, i) => [n, new Uint8Array(msg.buffers[i])]));
    const out = redealias(msg.volume_json, files, prior.volume_json, prior.files);
    if (out) {
      msg.volume_json = out.volume_json;
      for (const [name, bytes] of out.files) {
        const i = msg.names.indexOf(name);
        if (i >= 0) msg.buffers[i] = bytes.buffer;
        else msg.names.push(name), msg.buffers.push(bytes.buffer);
      }
    }
  }
  const dvel = new Map();
  msg.names.forEach((n, i) => n.endsWith("_DVEL.bin") && dvel.set(n, new Uint8Array(msg.buffers[i].slice(0))));
  prior = { volume_json: msg.volume_json, files: dvel };
  return msg;
}

async function fetchRaw(key) {
  const url = `${ARCHIVE}/${key}`;
  let cache = null;
  try {
    cache = await caches.open(RAW_CACHE);
    const hit = await cache.match(url);
    if (hit) return new Uint8Array(await hit.arrayBuffer());
  } catch {
    cache = null; // no Cache API (insecure context): just download
  }
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`GET ${url}: HTTP ${resp.status}`);
  const bytes = await resp.arrayBuffer();
  if (cache) {
    try {
      await cache.put(url, new Response(bytes.slice(0)));
      const held = await cache.keys(); // insertion order: drop the oldest
      for (const req of held.slice(0, Math.max(0, held.length - RAW_CACHE_FILES))) await cache.delete(req);
    } catch {
      // over quota, or another decoder trimmed first: the file is just not kept
    }
  }
  return new Uint8Array(bytes);
}

async function update({ site, at = "", from = "", to = "", workers = POOL_SIZE }) {
  const keys = resolve_keys(site, at, from, to, bucket(ARCHIVE));
  const n = Math.min(keys.length, workers);
  if (n <= 1) {
    for (const [i, key] of keys.entries()) {
      line(`[${i + 1}/${keys.length}] ${fileName(key)}`);
      const [msg] = volumeMessage(decode(await fetchRaw(key), key));
      withPrior(msg);
      postMessage(msg, msg.buffers);
      line(msg.name); // as `nexrad update` prints each decoded volume
    }
    return;
  }
  const pool = Array.from({ length: n }, () => new Worker(import.meta.url, { type: "module" }));
  try {
    await new Promise((resolve, reject) => {
      const ready = new Map(); // index -> "decoded" message, held until its turn
      let next = 0; // next key to hand out
      let done = 0; // volumes passed on
      const progress = () => done < keys.length && line(`[${done + 1}/${keys.length}] ${fileName(keys[done])}`);
      // At most 2n keys past the one being waited for, so one slow file cannot let the rest
      // pile up decoded in memory.
      const dispatch = (w) => {
        w.busy = next < keys.length && next < done + 2 * n;
        if (w.busy) w.postMessage(JSON.stringify({ cmd: "decode", key: keys[next], index: next++ }));
      };
      for (const w of pool) {
        w.onmessage = ({ data }) => {
          if (data.type === "error") return reject(new Error(`${fileName(keys[data.index])}: ${data.message}`));
          ready.set(data.index, data);
          while (ready.has(done)) {
            const msg = withPrior({ ...ready.get(done), type: "volume" });
            ready.delete(done++);
            postMessage(msg, msg.buffers);
            line(msg.name);
            progress();
          }
          if (done === keys.length) return resolve();
          dispatch(w);
          for (const idle of pool) if (!idle.busy) dispatch(idle);
        };
        w.onerror = (e) => {
          e.preventDefault();
          reject(new Error(`decoder worker failed: ${e.message}`));
        };
      }
      progress();
      pool.forEach(dispatch);
    });
  } finally {
    pool.forEach((w) => w.terminate());
  }
}

function follow({ site, interval = 5, hint = null }) {
  if (typeof SharedArrayBuffer === "undefined") {
    throw new Error("live needs a cross-origin isolated page (COOP/COEP headers)");
  }
  const nap = new Int32Array(new SharedArrayBuffer(4));
  const sleep = () => {
    Atomics.wait(nap, 0, 0, interval * 1000);
    return true;
  };
  const remember = (volume, time_ms) => postMessage({ type: "ring", volume, time_ms });
  live(site, bucket(CHUNKS), sleep, postVolume, line, hint?.volume ?? null, hint?.time_ms ?? null, remember);
}

onmessage = async ({ data }) => {
  const req = JSON.parse(data);
  try {
    await init();
    if (req.cmd === "decode") {
      // a pool member: one answer per key, and it stays up for the next
      return postMessage(...volumeMessage(decode(await fetchRaw(req.key), req.key), { type: "decoded", index: req.index }));
    }
    if (req.cmd === "update") await update(req);
    else if (req.cmd === "live") follow(req);
    else throw new Error(`unknown command ${req.cmd}`);
    postMessage({ type: "done" });
  } catch (e) {
    postMessage({ type: "error", index: req.index, message: String(e?.message ?? e) });
  }
};
