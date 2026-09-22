// Static server for the web build with the headers a threaded Godot export needs
// (cross-origin isolation, for SharedArrayBuffer). Local testing only:
//   node web/serve.mjs [DIR=export/web] [PORT=8060] [--pages]
// --pages leaves the isolation headers out, as GitHub Pages does, so the export's service
// worker has to supply them (see web/export_presets.template.cfg).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

export function serve(root, listenPort, { host = "127.0.0.1", isolate = true } = {}) {
  const server = createServer(async (req, res) => {
    let path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
    if (path.endsWith("/")) path += "index.html";
    try {
      const body = await readFile(join(root, path));
      const headers = { "content-type": types[extname(path)] || "application/octet-stream", "cache-control": "no-cache" };
      if (isolate) {
        headers["cross-origin-opener-policy"] = "same-origin";
        headers["cross-origin-embedder-policy"] = "require-corp";
      }
      res.writeHead(200, headers);
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  return new Promise((ok) => server.listen(listenPort, host, () => ok(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2).filter((a) => a !== "--pages");
  const isolate = !process.argv.includes("--pages");
  const [dir = "export/web", port = 8060] = args;
  await serve(dir, +port, { isolate });
  console.log(`serving ${dir} on http://127.0.0.1:${port}/${isolate ? "" : " (no isolation headers)"}`);
}
