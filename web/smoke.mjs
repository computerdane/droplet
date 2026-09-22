// Web smoke test: serves a web build, opens it in headless Chromium over the DevTools
// protocol, waits for the startup fetch to finish ("fetch: ... done" from main.gd) and saves a
// screenshot. Fails on page errors or a failed fetch. Needs network (the Unidata buckets).
//   nix shell nixpkgs#nodejs nixpkgs#chromium -c node web/smoke.mjs [DIR=export/web] [OUT=export/smoke.png] [QUERY]
// QUERY defaults to "site=KTLX&time=20130520_200359" (the Moore tornado). SMOKE_PAGES=1 serves without the
// isolation headers, as GitHub Pages does (the service worker supplies them after one reload).
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { serve } from "./serve.mjs";

const [dir = "export/web", out = "export/smoke.png", query = "site=KTLX&time=20130520_200359"] = process.argv.slice(2);
const TIMEOUT_MS = +(process.env.SMOKE_TIMEOUT_MS || 120_000);
const server = await serve(dir, 0, { isolate: !process.env.SMOKE_PAGES });
const url = `http://127.0.0.1:${server.address().port}/index.html?${query}`;
const profile = mkdtempSync(join(tmpdir(), "droplet-smoke-"));
const chrome = spawn(
  process.env.CHROMIUM || "chromium",
  ["--headless=new", "--no-sandbox", "--enable-unsafe-swiftshader", "--use-angle=swiftshader", "--window-size=1280,800",
    "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"],
  { stdio: ["ignore", "ignore", "pipe"] },
);
const devtools = await new Promise((ok) => {
  let err = "";
  chrome.stderr.on("data", (d) => {
    err += d;
    const m = err.match(/DevTools listening on (ws:\S+)/);
    if (m) ok(m[1]);
  });
});
const targets = await (await fetch(devtools.replace("ws://", "http://").replace(/\/devtools\/.*/, "/json"))).json();
const ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
await new Promise((ok) => ws.addEventListener("open", ok));
let id = 0;
const pending = new Map();
const send = (method, params = {}) =>
  new Promise((ok) => {
    pending.set(++id, ok);
    ws.send(JSON.stringify({ id, method, params }));
  });
let finish;
const result = new Promise((ok) => (finish = ok));
const errors = [];
ws.addEventListener("message", ({ data }) => {
  const msg = JSON.parse(data);
  if (msg.id && pending.has(msg.id)) return pending.get(msg.id)(msg.result);
  // only the last page load counts (the service worker reloads the page to install itself)
  if (msg.method === "Page.frameNavigated" && !msg.params.frame.parentId) errors.length = 0;
  if (msg.method === "Runtime.consoleAPICalled") {
    const text = msg.params.args.map((a) => a.value ?? a.description ?? "").join(" ");
    console.log(`[${msg.params.type}] ${text}`);
    if (msg.params.type === "error") errors.push(text);
    if (text.startsWith("fetch: ")) finish(text);
  } else if (msg.method === "Runtime.exceptionThrown") {
    const text = msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text;
    console.log(`[exception] ${text}`);
    errors.push(text);
  }
});
await send("Runtime.enable");
await send("Page.enable");
const t0 = Date.now();
await send("Page.navigate", { url });
const line = await Promise.race([result, new Promise((ok) => setTimeout(() => ok("timeout"), TIMEOUT_MS))]);
console.log(`fetch finished after ${((Date.now() - t0) / 1000).toFixed(1)} s: ${line}`);
await new Promise((ok) => setTimeout(ok, 3000)); // let the frame upload and draw
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(out, Buffer.from(shot.data, "base64"));
console.log(`screenshot: ${out}`);
chrome.kill();
server.close();
const ok = line.includes(" done") && errors.length === 0;
if (!ok) console.log(`FAILED: ${errors.length} console errors`);
process.exit(ok ? 0 : 1);
