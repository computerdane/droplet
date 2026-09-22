// The web build's stand-in for the `nexrad` CLI (scripts/fetcher.gd starts one module worker per
// job and terminates it to stop, as it kills a process on the desktop). Posted one JSON request:
//   {"cmd": "update", "site": "KTLX", "at": "", "from": "", "to": ""}   (ISO times or "")
//   {"cmd": "live", "site": "KTLX", "interval": 5}
// Answers with {type: "line", line} (the CLI's output lines, "[i/n] file" progress included),
// {type: "volume", name, volume_json, names, buffers} (sweep file names and their float16
// ArrayBuffers, transferred), and finally {type: "done"} or {type: "error", message}.
//
// Both Unidata buckets allow anonymous CORS reads and listings. Listings go through synchronous
// XHR, which workers may use, because the key selection and live loop in nexrad-wasm are blocking
// Rust. Raw archive files are immutable and kept in the Cache API, so revisiting an event costs
// only the decode.
import init, { decode, live, resolve_keys } from "./nexrad_wasm.js";

const ARCHIVE = "https://unidata-nexrad-level2.s3.amazonaws.com";
const CHUNKS = "https://unidata-nexrad-level2-chunks.s3.amazonaws.com";
const RAW_CACHE = "droplet-raw-v1";

const line = (text) => postMessage({ type: "line", line: text });

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

function postVolume(vol) {
  const names = [...vol.files.keys()];
  const buffers = names.map((n) => vol.files.get(n).buffer);
  postMessage({ type: "volume", name: vol.name, volume_json: vol.volume_json, names, buffers }, buffers);
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
  if (cache) await cache.put(url, new Response(bytes.slice(0))).catch(() => {});
  return new Uint8Array(bytes);
}

async function update({ site, at = "", from = "", to = "" }) {
  const keys = resolve_keys(site, at, from, to, bucket(ARCHIVE));
  for (const [i, key] of keys.entries()) {
    line(`[${i + 1}/${keys.length}] ${key.split("/").pop()}`);
    const vol = decode(await fetchRaw(key));
    postVolume(vol);
    line(vol.name); // as `nexrad update` prints each decoded volume
  }
}

function follow({ site, interval = 5 }) {
  if (typeof SharedArrayBuffer === "undefined") {
    throw new Error("live needs a cross-origin isolated page (COOP/COEP headers)");
  }
  const nap = new Int32Array(new SharedArrayBuffer(4));
  const sleep = () => {
    Atomics.wait(nap, 0, 0, interval * 1000);
    return true;
  };
  live(site, bucket(CHUNKS), sleep, postVolume, line);
}

onmessage = async ({ data }) => {
  try {
    await init();
    const req = JSON.parse(data);
    if (req.cmd === "update") await update(req);
    else if (req.cmd === "live") follow(req);
    else throw new Error(`unknown command ${req.cmd}`);
    postMessage({ type: "done" });
  } catch (e) {
    postMessage({ type: "error", message: String(e?.message ?? e) });
  }
};
