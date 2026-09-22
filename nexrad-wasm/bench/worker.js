// Decodes archive files with the wasm build, off the main thread.
import init, { decode } from "../pkg/nexrad_wasm.js";

const t0 = performance.now();
const ready = init().then(() => performance.now() - t0);

onmessage = async ({ data: { url, runs } }) => {
  const init_ms = await ready;
  const raw = new Uint8Array(await (await fetch(url)).arrayBuffer());
  const times = [];
  let out;
  for (let i = 0; i < runs; i++) {
    const t = performance.now();
    out = decode(raw);
    times.push({ total_ms: performance.now() - t, read_ms: out.read_ms, encode_ms: out.encode_ms });
  }
  const files = [...out.files];
  postMessage(
    { url, init_ms, bytes: raw.length, times, name: out.name, volume_json: out.volume_json, files },
    files.map(([, b]) => b.buffer),
  );
};
