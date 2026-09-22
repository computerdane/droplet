# Roadmap

State of the project as of 2026-09-22, what comes next, how it will be tested, and how it
will be hosted. `CLAUDE.md` describes the architecture; this file is about direction.

## Where we are

**Pipeline (`nexrad/`, Python + numpy).** Level II decoder for both archive layouts
(bz2 LDM records and the older gzip stream, Message 31 only), archive fetch of the newest /
at-a-time / range of volumes, live following of the chunks bucket, region-based velocity
dealiasing (DVEL), VAD wind profile with Bunkers storm motion and SRH, basemap build,
and a CLI whose progress lines the UI parses.

**Viewer (`scripts/`, `shaders/`, Godot 4.7).** 2D plan view with basemap, rings and
decluttered city labels; eight fields with colormaps; loop playback over sequences with
scrubbing and live following; site picker and nearest-radar mosaic; 3D beam-height cones
and ray-marched volume rendering with an orbit camera; vertical cross-sections; storm-
relative velocity (manual or automatic); hodograph; VWP time-height barbs; hover readout in
2D, section and VWP; in-app fetch panel driving the sidecar; LRU volume cache with
background prefetch; responsive HUD; `key=value` options for scripted runs.

**Tests and tooling.** `tests/smoke.gd` (tilt selection, sequences, projection, preload,
beam model, storm motion lookup, readout), `tests/screenshot.gd`, `tests/frametimes.gd`,
gdformat and gdlint. `nexrad/synth.py` generates synthetic Archive2 files and fixture
volumes; `pytest` covers the decoder, dealiasing, VAD, chunk ring, `live()`, key selection
and the volume writer without network or real data (57 tests, ~10 s). All green.

**Gaps.**

- The Godot tests still read `data/volumes` by default. smoke.gd passes unchanged against the
  fixtures (verified by hand), but there is no runner that points it there yet.
- Nothing runs in CI yet.
- Screenshots are eyeballed; nothing catches a shader regression automatically.
- The hover readout skips 3D, sections use one site, live follows one site per process.

## Roadmap

Ordered by what unblocks the most.

1. **Test fixtures and CI.** Done: synthetic volume generator, pytest. Left: a Godot test
   runner that works without real data, golden screenshots under Xvfb, GitHub Actions.
   Prerequisite for everything below being safe to ship. See "Automated testing".
2. **Web build and hosting.** See "Web build". Includes URL-state permalinks, which fall
   out of the existing `key=value` options.
3. **Derived products.** Composite reflectivity, echo tops, VIL, azimuthal shear and
   rotation tracks, KDP, a hydrometeor classifier. These reuse the tilt arrays built for
   volume rendering.
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

- **Python unit tests (done, `tests/python/`).** `nexrad/synth.py` encodes synthetic
  Archive2 files in both layouts, so no raw file lands in git. Covers header parsing, LDM
  record iteration, moment scaling, sentinels, sweep grouping, partial volumes and the
  Message 31 size overflow; the dealias and VAD self-tests plus scoring against the synthetic
  scene's truth; the chunk ring and `live()` against canned S3 listings; key selection;
  `write_volume()` layout and values.
- **Godot unit tests without real data.** `python -m nexrad.synth` writes three fixture
  volumes (KTST ×2 and a KTSU neighbour, ~3.8 MB) to `tests/fixtures/volumes/`. They are
  generated deterministically rather than committed (~0.9 MB compressed per regeneration
  would pile up in history); CI runs the generator first. `volumes=` points the app at
  them. Next: a runner script discovers `test_*.gd` files, points `RadarLibrary` at the
  fixture root, and ports the smoke checks onto it. Keep one optional pass over real data.
- **Golden screenshots.** Xvfb plus the Compatibility driver render deterministically in
  software. Capture a fixed set of views of the fixture volume, compare against committed
  PNGs with a pixel-difference tolerance, regenerate goldens only with an explicit flag.
  Seed set: 2D DVEL with SRM and mosaic, 3D cones with mosaic, volume render, section with
  VWP, hodograph and a pinned hover.
- **Performance gate.** `frametimes.gd` fails above thresholds (median, p99, spike count),
  run nightly on a real loop rather than per commit.
- **Web smoke.** After exporting, load the page in headless Chromium over the DevTools
  protocol, assert the engine banner appears with zero console errors, screenshot. Once
  the fixture volume ships in the web pck this can screenshot actual radar.

One GitHub Actions workflow using the Nix flake: lint, pytest, Godot import plus unit
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

**What does not carry over.** The Python sidecar cannot run in a browser, so fetching,
decoding, dealiasing and VAD need a new home. Reads from `res://data` become HTTP fetches.
Worker threads need the threaded export plus the two cross-origin isolation headers. The
1 GiB cache budget must shrink.

**Pure client is possible but costly.** The archives are bzip2 and Godot only decompresses
gzip, deflate, zstd and brotli, so client decoding needs a JS bzip2 library through the
JavaScript bridge or a web GDExtension, plus a GDScript port of the parser. The numpy
dealiaser and VAD would not port well, so a pure client would ship without DVEL and winds.

**Decision: thin decode layer, mostly static.** A worker runs the existing Python
pipeline and writes the current on-disk format where a web server can serve it. The client
fetches per sweep, which is how the cache already loads. A live follower rewrites partial
volumes into the same directory and the client polls `volume.json` every few seconds with
ETag checks, as it polls the mtime today. The only real endpoint is a small
request-to-decode call for a time nobody has asked for yet.

**Client changes, in order.**

1. A volume source abstraction with a local-directory and an HTTP implementation behind
   `RadarLibrary`, `read_image()` and the two-byte readout (which on web reads from the
   cached Image instead of seeking a file).
2. The fetch panel calls the decode endpoint instead of spawning Python; hide process UI.
3. Options come from the URL query string on web (permalinks, same screenshot harness).
4. A platform-dependent cache budget and an explicit Compatibility renderer for web.
5. Basemap served from the same origin and cached in `user://`.

### Hosting

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
