// Runs the real Godot + decoder WASM in Chromium. SMOKE_FIXTURE supplies raw Archive2
// bytes in place of Unidata requests, blocks other external traffic, and checks two
// preview scopes on one origin. Without it this remains the live archive smoke test.
// nix develop -c node web/smoke.mjs [DIR] [SCREENSHOT] [QUERY]
// SMOKE_PAGES=1 omits isolation headers, exactly as GitHub Pages does.
// Offline, it also toggles the viewer's location (G) with geolocation denied, then granted
// and emulated by DevTools (no network: the position never leaves the browser).
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { serve } from "./serve.mjs";

const offline = process.env.SMOKE_FIXTURE && readFileSync(process.env.SMOKE_FIXTURE);
const [dir = "export/web", out = "export/smoke.png", query = offline
  ? "site=KTLX&time=20240501_220000&hover=0" : "site=KTLX&time=20130520_200359&hover=0"] = process.argv.slice(2);
const timeout = Number(process.env.SMOKE_TIMEOUT_MS || 120_000);
const work = mkdtempSync(join(tmpdir(), "droplet-smoke-"));
const paths = offline ? ["droplet/previews/pr-1", "droplet/previews/pr-2"] : ["app"];
for (const path of paths) {
  mkdirSync(dirname(join(work, "site", path)), { recursive: true });
  symlinkSync(resolve(dir), join(work, "site", path), "dir");
}
let server, chrome, ws;
const pending = new Map();
let sequence = 0;
let fatal;
const failure = new Promise((_, reject) => { fatal = reject; });
// Consume asynchronous failures even during cleanup; each operational wait races this.
failure.catch(() => {});
const wait = (promise) => Promise.race([promise, failure]);
const timer = setTimeout(() => fatal(new Error(`smoke test timed out after ${timeout} ms`)), timeout);
function send(method, params = {}, sessionId) {
  return wait(new Promise((resolve, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve, reject });
    ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
  }));
}
let completed;
let located; // resolves on the app's "location: ..." console line
let errors = [];
let downloads = 0;
const fixtureKey = "2024/05/01/KTLX/KTLX20240501_220000_V06";
async function intercept(params, sessionId) {
  const url = new URL(params.request.url);
  if (url.hostname === "127.0.0.1") {
    try {
      return await send("Fetch.continueRequest", { requestId: params.requestId }, sessionId);
    } catch (error) {
      // Installing the Pages service worker reloads the page and cancels old requests.
      if (!error.message.includes("Invalid InterceptionId")) throw error;
      return;
    }
  }
  const overlay = url.hostname === "mesonet.agron.iastate.edu"
    && ["/geojson/sbw.geojson", "/api/1/nws/spc_outlook.geojson"].includes(url.pathname);
  if (!overlay && url.hostname !== "unidata-nexrad-level2.s3.amazonaws.com") {
    throw new Error(`unexpected external request in offline smoke: ${url}`);
  }
  let body;
  if (overlay) {
    body = Buffer.from('{"type":"FeatureCollection","features":[]}');
  } else if (url.searchParams.has("list-type")) {
    const prefix = url.searchParams.get("prefix") || "";
    const contents = fixtureKey.startsWith(prefix) ? `<Contents><Key>${fixtureKey}</Key><Size>${offline.length}</Size></Contents>` : "";
    body = Buffer.from(`<ListBucketResult><IsTruncated>false</IsTruncated>${contents}</ListBucketResult>`);
  } else {
    assert.equal(url.pathname, `/${fixtureKey}`);
    downloads++;
    body = offline;
  }
  return send("Fetch.fulfillRequest", {
    requestId: params.requestId, responseCode: 200,
    responseHeaders: [
      { name: "Access-Control-Allow-Origin", value: "*" },
      { name: "Cross-Origin-Resource-Policy", value: "cross-origin" },
      { name: "Content-Type", value: url.search ? "application/xml" : "application/octet-stream" },
    ], body: body.toString("base64"),
  }, sessionId);
}
async function attached({ sessionId, targetInfo }) {
  // Catch nested decoder workers and service worker fetches as well as the page.
  if (["page", "worker", "service_worker"].includes(targetInfo.type)) {
    await send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true }, sessionId);
  }
  if (offline && ["page", "service_worker"].includes(targetInfo.type)) {
    await send("Fetch.enable", { patterns: [{ urlPattern: "*" }] }, sessionId);
  }
  await send("Runtime.runIfWaitingForDebugger", {}, sessionId);
  console.log(`attached ${targetInfo.type}`);
}
try {
  server = await serve(join(work, "site"), 0, { isolate: !process.env.SMOKE_PAGES });
  const origin = `http://127.0.0.1:${server.address().port}`;
  chrome = spawn(process.env.CHROMIUM || "chromium", [
    "--headless=new", "--no-sandbox", "--enable-unsafe-swiftshader", "--use-angle=swiftshader",
    "--window-size=1280,800", "--remote-debugging-port=0", `--user-data-dir=${join(work, "profile")}`,
    "--disable-background-networking", "--disable-component-update", "--no-first-run", "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  chrome.on("error", fatal);
  const devtools = await wait(new Promise((ok, reject) => {
    let stderr = "";
    chrome.once("exit", (code) => reject(new Error(`Chromium exited (${code}): ${stderr}`)));
    chrome.stderr.on("data", (chunk) => {
      stderr = (stderr + chunk).slice(-32_768);
      const match = stderr.match(/DevTools listening on (ws:\S+)/);
      if (match) ok(match[1]);
    });
  }));
  chrome.on("exit", (code) => fatal(new Error(`Chromium exited unexpectedly (${code})`)));
  const targets = await wait(fetch(devtools.replace("ws://", "http://").replace(/\/devtools\/.*/, "/json")).then((r) => r.json()));
  ws = new WebSocket(targets.find((t) => t.type === "page").webSocketDebuggerUrl);
  await wait(new Promise((ok, reject) => { ws.addEventListener("open", ok); ws.addEventListener("error", reject); }));
  ws.addEventListener("message", ({ data }) => {
    const msg = JSON.parse(data);
    if (msg.id) {
      const callback = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) callback?.reject(new Error(JSON.stringify(msg.error)));
      else callback?.resolve(msg.result);
      return;
    }
    if (msg.method === "Fetch.requestPaused") intercept(msg.params, msg.sessionId).catch(fatal);
    if (msg.method === "Target.attachedToTarget") attached(msg.params).catch(fatal);
    // The Pages isolation bootstrap may reload twice before the worker controls the
    // document. Judge the final document, not a discarded bootstrap page.
    if (msg.method === "Page.frameNavigated" && !msg.params.frame.parentId) errors = [];
    if (msg.method === "Runtime.consoleAPICalled") {
      const text = msg.params.args.map((a) => a.value ?? a.description ?? "").join(" ");
      console.log(`[${msg.params.type}] ${text}`);
      if (msg.params.type === "error") errors.push(text);
      if (text.startsWith("fetch: ")) completed?.(text);
      if (text.startsWith("location: ")) located?.(text);
    } else if (msg.method === "Runtime.exceptionThrown") {
      errors.push(msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
    }
  });
  await send("Runtime.enable");
  await send("Page.enable");
  if (offline) {
    await send("Fetch.enable", { patterns: [{ urlPattern: "*" }] });
    await send("Target.setAutoAttach", { autoAttach: true, waitForDebuggerOnStart: true, flatten: true });
  }
  const evaluate = async (expression) => {
    const response = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
    assert(!response.exceptionDetails, JSON.stringify(response.exceptionDetails));
    return response.result.value;
  };
  const capture = async (minimumColored = 1000) => {
    const shot = await send("Page.captureScreenshot", { format: "png" });
    // Inspect only the central viewport, excluding the toolbar and timeline. This
    // catches a blank engine canvas even when downloading/decoding succeeded.
    const pixels = await evaluate(`(async () => {
      const image = new Image();
      image.src = 'data:image/png;base64,${shot.data}';
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = image.width; canvas.height = image.height;
      const ctx = canvas.getContext('2d'); ctx.drawImage(image, 0, 0);
      const {data} = ctx.getImageData(image.width / 4, image.height / 4,
        Math.floor(image.width / 2), Math.floor(image.height / 2));
      let colored = 0, hash = 0;
      for (let i = 0; i < data.length; i += 4) {
        const hi = Math.max(data[i], data[i + 1], data[i + 2]);
        const lo = Math.min(data[i], data[i + 1], data[i + 2]);
        if (hi > 100 && hi - lo > 70) colored++;
        hash = (Math.imul(hash, 31) + data[i] + data[i + 1] * 3 + data[i + 2] * 7) | 0;
      }
      return {colored, hash};
    })()`);
    if (pixels.colored <= minimumColored) {
      mkdirSync(dirname(out), { recursive: true });
      writeFileSync(out.replace(/\.png$/, "-failure.png"), Buffer.from(shot.data, "base64"));
    }
    assert(pixels.colored > minimumColored, `radar must draw in the viewport: ${JSON.stringify(pixels)}`);
    return { ...shot, pixels };
  };
  let previousCaches = [];
  for (const [index, path] of paths.entries()) {
    errors = [];
    const result = new Promise((ok) => { completed = ok; });
    await send("Page.navigate", { url: `${origin}/${path}/index.html?${query}` });
    const line = await wait(result);
    assert.match(line, / done/, line);
    await wait(new Promise((ok) => setTimeout(ok, 3000))); // upload textures and render
    assert.deepEqual(errors, [], "browser errors");
    const status = await evaluate(`({ isolated: self.crossOriginIsolated,
      scope: navigator.serviceWorker.controller?.scriptURL,
      width: document.querySelector('canvas')?.width,
      height: document.querySelector('canvas')?.height })`);
    assert.equal(status.isolated, true, "Godot threads need isolation even without Pages headers");
    assert(status.width > 0 && status.height > 0, "Godot canvas must render");
    if (process.env.SMOKE_PAGES) assert.equal(status.scope, `${origin}/${path}/index.service.worker.js`);
    const shot = offline ? await capture() : await send("Page.captureScreenshot", { format: "png" });
    const destination = index ? out.replace(/\.png$/, "-second.png") : out;
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, Buffer.from(shot.data, "base64"));
    console.log(`screenshot: ${destination}`);
    if (offline) {
      await send("Input.dispatchKeyEvent", { type: "keyDown", key: "2", code: "Digit2", windowsVirtualKeyCode: 50 });
      await send("Input.dispatchKeyEvent", { type: "keyUp", key: "2", code: "Digit2", windowsVirtualKeyCode: 50 });
      await wait(new Promise((ok) => setTimeout(ok, 1000)));
      // Near-zero velocity uses a subdued palette; the synthetic rotation still
      // contributes hundreds of strongly colored pixels.
      const velocity = await capture(500);
      assert.notEqual(velocity.pixels.hash, shot.pixels.hash, "switching to velocity must change radar rendering");
      writeFileSync(destination.replace(/\.png$/, "-velocity.png"), Buffer.from(velocity.data, "base64"));
      assert.deepEqual(errors, [], "browser errors after switching fields");
      // The viewer's location: denied first (a notice, no marker), then granted at a fixed
      // position ~21 km southwest of KTLX, which must draw a marker in the viewport.
      const toggleLocation = async () => {
        const line = new Promise((ok) => { located = ok; });
        await send("Input.dispatchKeyEvent", { type: "keyDown", key: "g", code: "KeyG", windowsVirtualKeyCode: 71 });
        await send("Input.dispatchKeyEvent", { type: "keyUp", key: "g", code: "KeyG", windowsVirtualKeyCode: 71 });
        return wait(line);
      };
      await send("Browser.setPermission", { origin, permission: { name: "geolocation" }, setting: "denied" });
      assert.equal(await toggleLocation(), "location: Location permission denied");
      await send("Browser.grantPermissions", { origin, permissions: ["geolocation"] });
      await send("Emulation.setGeolocationOverride", { latitude: 35.2, longitude: -97.45, accuracy: 50 });
      assert.equal(await toggleLocation(), "location: shown");
      await wait(new Promise((ok) => setTimeout(ok, 1000)));
      const marked = await capture(500);
      assert.notEqual(marked.pixels.hash, velocity.pixels.hash, "the location marker must draw");
      writeFileSync(destination.replace(/\.png$/, "-location.png"), Buffer.from(marked.data, "base64"));
      assert.deepEqual(errors, [], "browser errors after showing the location");
      await send("Browser.resetPermissions", {});
      await send("Emulation.clearGeolocationOverride");
      const keys = await evaluate("caches.keys()");
      const prefix = `Droplet-sw-cache-${encodeURIComponent(`${origin}/${path}/`)}-`;
      assert(keys.some((key) => key.startsWith(prefix)), "scope-specific PWA cache missing");
      for (const prior of previousCaches) assert(keys.includes(prior), `preview evicted another scope: ${prior}`);
      previousCaches = keys;
    }
  }
  if (offline) assert.equal(downloads, paths.length, "each isolated preview must fetch and decode the fixture");
  console.log("browser smoke passed");
} catch (error) {
  console.error(error);
  process.exitCode = 1;
} finally {
  clearTimeout(timer);
  ws?.close();
  for (const callback of pending.values()) callback.reject(new Error("smoke test finished"));
  if (chrome && chrome.exitCode === null) {
    chrome.kill("SIGKILL");
    await new Promise((ok) => {
      const cleanup = setTimeout(ok, 5000);
      chrome.once("exit", () => { clearTimeout(cleanup); ok(); });
    });
  }
  server?.closeAllConnections();
  server?.close();
  rmSync(work, { recursive: true, force: true });
}
