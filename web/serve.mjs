// Static server for the web build with the headers a threaded Godot export needs
// (cross-origin isolation, for SharedArrayBuffer). Local testing only:
//   node web/serve.mjs [DIR=export/web] [PORT=8060]
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const dir = process.argv[2] || "export/web";
const port = +(process.argv[3] || 8060);
const types = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".wasm": "application/wasm",
  ".pck": "application/octet-stream",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

export function serve(root, listenPort, host = "127.0.0.1") {
  const server = createServer(async (req, res) => {
    let path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
    if (path.endsWith("/")) path += "index.html";
    try {
      const body = await readFile(join(root, path));
      res.writeHead(200, {
        "content-type": types[extname(path)] || "application/octet-stream",
        "cross-origin-opener-policy": "same-origin",
        "cross-origin-embedder-policy": "require-corp",
        "cache-control": "no-cache",
      });
      res.end(body);
    } catch {
      res.writeHead(404).end();
    }
  });
  return new Promise((ok) => server.listen(listenPort, host, () => ok(server)));
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await serve(dir, port);
  console.log(`serving ${dir} on http://127.0.0.1:${port}/`);
}
