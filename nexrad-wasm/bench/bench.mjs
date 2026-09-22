// Times the wasm decoder in headless Chromium and saves its output for comparison with
// `nexrad decode`. Run from the repo root after nexrad-wasm/build.sh:
//   nix shell nixpkgs#nodejs nixpkgs#chromium -c node nexrad-wasm/bench/bench.mjs OUT_DIR RUNS raw1 raw2 ...
// Writes OUT_DIR/<volume>/{volume.json,sNN_FIELD.bin} and OUT_DIR/report.json.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, extname, join, normalize } from "node:path";

const [out, runs, ...raws] = process.argv.slice(2);
const root = process.cwd();
const types = { ".html": "text/html", ".js": "text/javascript", ".wasm": "application/wasm" };

const server = createServer((req, res) => {
  const path = normalize(decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (req.method === "POST") {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      res.end();
      if (path === "/done") {
        writeFileSync(join(out, "report.json"), body);
        console.log(JSON.stringify(JSON.parse(body), null, 1));
        chrome.kill();
        server.close();
      } else {
        const dest = join(out, path.replace(/^\/result\//, ""));
        mkdirSync(dirname(dest), { recursive: true });
        writeFileSync(dest, body);
      }
    });
    return;
  }
  try {
    const body = readFileSync(join(root, path));
    res.writeHead(200, { "content-type": types[extname(path)] || "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});

let chrome;
server.listen(0, "127.0.0.1", () => {
  mkdirSync(out, { recursive: true });
  const url = `http://127.0.0.1:${server.address().port}/nexrad-wasm/bench/index.html?post=1&runs=${runs}&files=${raws.map((r) => "/" + r).join(",")}`;
  chrome = spawn(process.env.CHROMIUM || "chromium", ["--headless=new", "--no-sandbox", "--disable-gpu", `--user-data-dir=${join(out, ".chrome")}`, url], {
    stdio: "ignore",
  });
});
