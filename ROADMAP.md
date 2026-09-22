# Roadmap

State of the project as of 2026-09-22, what comes next, how it will be tested, and how it
will be hosted. `CLAUDE.md` describes the architecture; this file is about direction.

## Where we are

**Pipeline (`nexrad/`, Rust).** Level II decoder for both archive layouts
(bz2 LDM records and the older gzip stream, Message 31 only), archive fetch of the newest /
at-a-time / range of volumes, live following of the chunks bucket, region-based velocity
dealiasing (DVEL), VAD wind profile with Bunkers storm motion and SRH, basemap build,
and a CLI whose progress lines the UI parses. Ported from Python/numpy on 2026-09-22 with
bit-identical output; decode + dealias + VAD + write is ~0.45 s per volume, and the library
has no C or platform dependencies, so it also compiles to WebAssembly.

**Viewer (`scripts/`, `shaders/`, Godot 4.7).** 2D plan view with basemap, rings and
decluttered city labels; eight fields with colormaps; loop playback over sequences with
scrubbing and live following; site picker and nearest-radar mosaic; 3D beam-height cones
and ray-marched volume rendering with an orbit camera; vertical cross-sections; storm-
relative velocity (manual or automatic); hodograph; VWP time-height barbs; hover readout in
2D, section and VWP; in-app fetch panel driving the sidecar; LRU volume cache with
background prefetch; responsive HUD; `key=value` options for scripted runs.

**Tests and tooling.** `tests/run.gd` runs the Godot unit tests in `tests/unit/` (tilt
selection, sequences, projection, preload, beam model, storm motion lookup, readout) against
the synthetic fixtures, or real data with `volumes=`, `tests/screenshot.gd`, `tests/frametimes.gd`,
gdformat and gdlint. `nexrad/src/synth.rs` generates synthetic Archive2 files and fixture
volumes; `cargo test` covers the decoder, dealiasing, VAD, chunk ring, `live()`, key
selection, the basemap readers and the volume writer without network or real data (43
tests, ~6 s). All green.

**Gaps.**

- The hover readout skips 3D, sections use one site, live follows one site per process.

## Roadmap

Ordered by what unblocks the most.

1. **Test fixtures and CI.** Done: synthetic volume generator, `cargo test`, Godot test runner
   on the fixtures, golden screenshots under Xvfb (`tests/golden.sh`), GitHub Actions
   (`.github/workflows/ci.yml`). Left: the nightly performance gate.
   Prerequisite for everything below being safe to ship. See "Automated testing".
2. **Web build and hosting.** See "Web build". Includes URL-state permalinks, which fall
   out of the existing `key=value` options.
3. **Derived products.** Done: composite reflectivity, echo tops and VIL (nexrad/src/products.rs,
   plan view, 9 cycles them), azimuthal shear and KDP (nexrad/src/fields.rs, per-gate fields
   next to the moments like DVEL; 0 toggles them). Left: rotation tracks, a hydrometeor
   classifier.
4. **Context overlays.** NWS warning polygons and SPC outlooks from the public NWS API,
   storm cell identification and tracking with motion vectors, tornado debris signature
   flags (low RHO inside high REF and rotation).
5. **Finishing 3D.** Hover pick against the cones, the A-B section line drawn in 3D,
   mosaic cross-sections.
6. **Data quality.** Temporal dealiasing against the previous volume, VAD as a dealiasing
   reference, caching the live ring position, multi-site live in one process, a disk quota
   for `data/`.
7. **Reach.** Message 1 parsing for pre-2008 archives, loop export to video, touch
   controls, a bookmark list of notable events.

## Automated testing

Five layers, cheapest first. Each maps onto a tool already in the dev shell.

- **Rust unit tests (done, `cargo test`).** `nexrad/src/synth.rs` encodes synthetic
  Archive2 files in both layouts, so no raw file lands in git. Covers header parsing, LDM
  record iteration, moment scaling, sentinels, sweep grouping, partial volumes and the
  Message 31 size overflow; the dealias and VAD self-tests plus scoring against the synthetic
  scene's truth; the chunk ring and `live()` against canned S3 listings; key selection;
  `write_volume()` layout and values.
- **Godot unit tests without real data.** `nexrad synth` writes three fixture
  volumes (KTST ×2 and a KTSU neighbour, ~3.8 MB) to `tests/fixtures/volumes/`. They are
  generated deterministically rather than committed (~0.9 MB compressed per regeneration
  would pile up in history); CI runs the generator first. `volumes=` points the app at
  them. Done: `tests/run.gd` discovers `tests/unit/test_*.gd`, points `RadarLibrary` at the
  fixture root and asserts exact fixture facts (split cut + SAILS tilt choice, KTSU borrowing
  KTST's storm motion); `volumes=res://data/volumes` is the optional pass over real data.
- **Golden screenshots.** Xvfb plus the Compatibility driver render deterministically in
  software. Capture a fixed set of views of the fixture volume, compare against committed
  PNGs with a pixel-difference tolerance, regenerate goldens only with an explicit flag.
  Seed set: 2D DVEL with SRM and mosaic, 3D cones with mosaic, volume render, section with
  VWP, hodograph and a pinned hover.
- **Performance gate.** `frametimes.gd` fails above thresholds (median, p99, spike count),
  run nightly on a real loop rather than per commit.
- **Web smoke (done, `web/smoke.mjs`).** Serves the export, loads a permalink in headless
  Chromium over the DevTools protocol, waits for the startup fetch to finish with zero
  console errors, screenshots actual radar. Needs network (the Unidata buckets).

One GitHub Actions workflow using the Nix flake: lint, `cargo test`, Godot import plus unit
tests, Xvfb screenshots, web export uploaded as an artifact. A `nix flake check` target
runs the same set locally.

## Web build

**Verified 2026-09-22.** Godot 4.7.2 exports the project for web once its templates are
symlinked into `~/.local/share/godot/export_templates/4.7.2.stable` (the flake's
`GODOT_EXPORT_TEMPLATES` alone is not enough). The `Web` preset lives in the gitignored
`export_presets.cfg` (threads on, extensions off):

```sh
godot --headless --path . --export-release Web out/index.html
```

The page boots in headless Chromium on WebGL2 with zero console errors, and all five
radar shaders render on the desktop through the same GLES3 backend
(`godot --rendering-driver opengl3 ...`). Both Unidata buckets answer browser requests
directly (wildcard CORS on listings and objects); the NOAA bucket refuses anonymous
listing.

| Item                                | Uncompressed | Gzipped  |
| ----------------------------------- | ------------ | -------- |
| Engine wasm                         | 38.8 MB      | 10.2 MB  |
| Decoded volume, all fields          | 84 MB        | 10.6 MB  |
| One REF sweep                       | 2.6 MB       | 0.22 MB  |
| One VEL or DVEL sweep               | 1.7 MB       | 0.14 MB  |
| Basemap                             | 21 MB        | 9.2 MB   |
| Raw archive file                    | 7 to 11 MB   | (bz2)    |
| Decode + dealias + VAD, one core    | 1.5 s/volume |          |

**What does not carry over.** The native CLI cannot be spawned from a browser, so fetching,
decoding, dealiasing and VAD need a new home. Reads from `res://data` become HTTP fetches.
Worker threads need the threaded export plus the two cross-origin isolation headers. The
1 GiB cache budget must shrink.

**Pure client is now the plan.** The `nexrad` crate is pure Rust (bzip2, flate2, half,
serde; networking sits behind the `native` feature), so it compiles to WebAssembly with
wasm-bindgen and runs in a Web Worker: the worker fetches archive files or live chunks
straight from the Unidata buckets (wildcard CORS), decodes, dealiases and fits the VAD, and
hands `volume.json` plus float16 sweep buffers to Godot through `JavaScriptBridge`, the same
format the cache reads today. Nothing runs on a server; the site is static files. The cost
is bandwidth and CPU on the client: a raw archive is 7 to 11 MB per volume against ~0.2 MB
per served sweep, and one volume is expected to take a few seconds of wasm time (native is
0.45 s). Cache decoded volumes in IndexedDB or OPFS so each one is paid for once, and use
several workers for loops and mosaics. Live latency stays at seconds: the worker polls the
chunks bucket exactly as `live` does.

**Fallback: thin decode layer.** If client bandwidth turns out to matter (long historical
loops, big mosaics), the same crate runs as a native worker (`nix build` packages it) that
writes decoded volumes where a web server can serve them, and the client fetches per sweep.
The decision is deferred until the wasm build is measured.

**Client changes, in order.**

1. Done: a volume source abstraction (`DirSource`, `MemorySource`) behind `RadarLibrary`,
   `read_image()` and the two-byte readout.
2. Done: the fetch panel drives `web/nexrad_worker.js` (nexrad-wasm in a Web Worker, one
   per job) instead of spawning the binary. Measured in headless Chromium: the Moore volume
   from a permalink in 3.9 s, a 30 min range (7 volumes) in 10 s, live KTLX seconds behind.
3. Done: options come from the URL query string on web, and a URL without `fetch=` fetches
   what it points at (`time=`, else live), so every link is a permalink.
4. Done: web budgets (384 MB textures, 900 MB of decoded volumes in memory; the heap caps
   at 2 GB). Web already renders with Compatibility.
5. Done: the basemap is served next to index.html (`web/build.sh` copies `data/basemap`; the Pages
   workflow runs `nexrad basemap`) and downloaded in the background; views build it when it
   arrives (`Basemap.when_loaded`). Shared borders are stored once and every run between
   junctions is simplified (~60 m), so it is 7.8 MB instead of 21 MB (the browser caches it).
6. Done: an update of several volumes decodes on a pool of up to four nested workers,
   in key order (mosaic neighbours are separate jobs, so already separate workers). With
   the raw files cached, the 7-volume Moore range decodes in ~2 s instead of 3.4 s (16
   cores; concurrent decoders slow each other, six at once are slower than four); cold,
   it is download-bound. The raw cache keeps the newest 300 files. Live is greyed out and
   a bare URL fetches the newest volume on a page without cross-origin isolation.
   Decoded volumes are deliberately not cached: 84 MB each against a 7 to 11 MB raw file
   that re-decodes in ~0.5 s.
7. Done: hosted on GitHub Pages, https://computerdane.github.io/droplet/, built and deployed by
   `.github/workflows/pages.yml` on every push to main. Godot's PWA service worker supplies
   the isolation headers (one reload on the first visit); history, ranges and live all work
   through it (`SMOKE_PAGES=1` smoke test).

### Hosting

**Chosen for the pure client: GitHub Pages** (see "Client changes" 7). The notes below are
for the thin-decode-layer fallback, where data and a worker live next to the app.

**Chosen: bludgeonder (danix), same origin for app and data.** The box already has nginx
with DNS-01 certs, a dynamic-IP record updater, a public 80/443 door, fail2ban, a 7 TB
array and an always-on posture. Serving the export and the decoded volumes from one vhost
removes CORS, cross-origin resource headers and the service-worker workaround: nginx sends
the isolation headers as real headers, there is no per-file size limit or write budget,
and live data at seconds of latency is natural because the follower writes to the
directory nginx serves.

In danix terms (host-local, since only bludgeonder fronts it):

- a name such as `radar.nix.gdn` in `hosts/bludgeonder/domains.nix`, with A/AAAA and an
  `acme` entry in the `nix.gdn` block of `services.dns-update`;
- a vhost in `hosts/bludgeonder/web.nix` with a `root` for the export, a location for the
  volumes directory, `Cross-Origin-Opener-Policy: same-origin` and
  `Cross-Origin-Embedder-Policy: require-corp`, `gzip_static` for pre-compressed wasm and
  sweep files, long immutable caching for archive volumes, `no-cache` on `volume.json`;
- a systemd worker running the live follower for a few sites plus the on-demand decoder,
  with a state directory nginx can read; packaged as a flake output of this repo that
  danix takes as an input (rsync until then);
- the decode endpoint behind the existing `limit_req` pattern, LAN/tunnel-only at first.

Watch: upload bandwidth of the AT&T line (a first visit is ~10 MB, a frame a fraction of
a megabyte), bludgeonder's existing load (one live site is under 1 % duty cycle), and
public exposure (the app is static files; the decode endpoint is the only input-taking
code, so gate and rate-limit it from day one).

**Free-cloud alternative, if the home box is ever out.** GitHub Pages for the app (the
wasm fits; the Godot PWA "ensure cross-origin isolation headers" option supplies the
headers via a service worker), Cloudflare R2 for data (10 GB, 1M writes, 10M reads per
month, zero egress; pack one object per field to stay under the write cap), and a home
machine or an Oracle Always Free VM (2 OCPU / 12 GB since June 2026) for the worker.
Cloudflare Pages caps files at 25 MiB, so the wasm would have to live on R2. Google's free
micro VM charges egress beyond 1 GB/month, so it is unsuitable for the worker.
