# droplet

Weather radar visualizer. Godot 4.7 renders NEXRAD Level II data; a Rust crate (`nexrad/`,
CLI `nexrad`) fetches and decodes it. Everything runs from the Nix dev shell (`nix develop`,
or direnv). Godot, gdformat/gdlint and the Rust toolchain are all provided; `cargo build
--release` puts `nexrad` on the shell's PATH (`nix build` packages the same binary).

Goals: **live** view that is never behind (seconds, via the real-time chunks bucket) and
**history** browsing of any volume back to ~2008 (via the archive mirror), with visualizations
that go well beyond a flat reflectivity map.

## Commands

```sh
cargo build --release                              # the nexrad CLI -> nexrad/target/release/ (on PATH in the dev shell)
nexrad update KTLX                                 # newest archive volume -> data/volumes/
nexrad update KTLX --at 2013-05-20T20:00Z          # historical volume (Moore, OK tornado)
nexrad update KTLX --from ... --to ...             # a range of volumes
nexrad live KTLX                                   # poll chunks bucket, rewrite partial volume as it grows
nexrad basemap                                     # once: Census states/counties + cities -> data/basemap/
nexrad decode data/raw/*_V06*                      # re-decode everything (e.g. after decoder/dealias changes)
nexrad winds [data/volumes/...]                    # (re)compute VAD winds + storm motion without re-decoding
nexrad synth                                       # synthetic fixture volumes -> tests/fixtures/volumes/
cargo test                                         # Rust tests (decoder, dealias, VAD, chunks, live, fixtures); no network, ~6 s
cargo clippy --all-targets && cargo fmt --check    # lint (rustfmt.toml: 140 columns)
nexrad-wasm/build.sh                               # browser decoder -> nexrad-wasm/pkg/ (wasm-bindgen + wasm-opt)
nix shell nixpkgs#nodejs nixpkgs#chromium -c node nexrad-wasm/bench/bench.mjs OUT 5 data/raw/<file> ...  # time it headless, save output
web/build.sh                                       # web app -> export/web/ (Godot export + wasm + worker)
node web/serve.mjs                                 # serve it on :8060 with COOP/COEP (--pages: without, like GitHub Pages)
nix shell nixpkgs#nodejs nixpkgs#chromium -c node web/smoke.mjs   # headless: load ?site=KTLX&time=20130520_200359, screenshot
SMOKE_PAGES=1 nix shell nixpkgs#nodejs nixpkgs#chromium -c node web/smoke.mjs   # same, served the way Pages serves it
godot --editor                                     # open project
godot                                               # run main scene
godot --headless --path . --import                  # (re)build .godot/ cache after adding scripts/scenes
godot --headless --path . --script res://tests/run.gd   # Godot unit tests on the fixtures
godot --headless --path . --script res://tests/run.gd -- volumes=res://data/volumes only=readout
godot --path . --script res://tests/screenshot.gd -- out.png time=20130520_200359 view=3d mosaic=1
godot --path . --script res://tests/screenshot.gd -- out.png time=20130520_200359 vwp=1 hover=560,380
godot --path . --script res://tests/screenshot.gd -- out.png volumes=res://tests/fixtures/volumes site=KTST
godot --path . -- site=KTLX fetch=2013-05-20T20:00Z  # start with a fetch (also latest, live, <from>/<to>)
godot --path . --script res://tests/frametimes.gd -- frames=1500 view=3d mosaic=1 play=1 fps=15 time=20130520_193407
gdformat scripts tests && gdlint scripts tests
```

## Layout

- `nexrad/` – Cargo workspace member (`Cargo.toml` at the repo root, build output in `nexrad/target/` via
  `.cargo/config.toml`). Library + `nexrad` binary; the `native` feature (default) holds networking and the CLI
  so the library also builds for wasm. Unit tests sit next to the code (`#[cfg(test)]`, 43 of them).
- `nexrad-wasm/` – wasm-bindgen wrapper (workspace member, `nexrad` without `native`): `decode(bytes)` →
  `{name, volume_json, files: Map<sNN_FIELD.bin, Uint8Array>}` via `volume::encode_volume()`, byte-identical to
  `nexrad decode`; `resolve_keys(site, at, from, to, bucket)` and `live(site, bucket, sleep, emit, log)` run the
  CLI's key selection and live loop over a `Bucket` whose `list`/`get` are synchronous JS functions. On wasm32 the
  record loop is serial (rayon is a non-wasm dependency). `bench/` = Web Worker page + a Node driver that serves
  it to headless Chromium and writes the results to disk.
- `web/` – the static web app. `nexrad_worker.js` = the browser's `nexrad` CLI: one module worker per job
  (`{"cmd": "update"|"live", ...}` in; `line`/`volume`/`done`/`error` messages out, sweep buffers transferred),
  sync XHR for listings (workers allow it; the Rust is blocking), raw archive files kept in the Cache API (newest
  300), live sleeps via `Atomics.wait` (needs cross-origin isolation; `Fetcher.can_live` greys out Live without it).
  An update of several volumes decodes on a pool of nested workers (`{"cmd": "decode"}`, min(4, cores − 2)) and
  passes the volumes on in key order. `build.sh` exports Godot (seeding the gitignored
  `export_presets.cfg` from `web/export_presets.template.cfg`) and copies the wasm + worker next to index.html;
  `serve.mjs` serves with COOP/COEP; `smoke.mjs` drives headless Chromium over CDP. Hosted on GitHub Pages
  (https://computerdane.github.io/droplet/, `.github/workflows/pages.yml` runs build.sh in the flake on every push
  to main). Pages cannot send COOP/COEP, so the preset enables Godot's PWA service worker, which adds them, plus a
  `head_include` that reloads once that worker controls the page (Godot's shell can reload too early). Changes to
  the template reach a local `export_presets.cfg` only if you delete it (build.sh seeds it when missing).
- `nexrad/src/level2.rs` – Archive2 / Message 31 decoder (bzip2 + flate2 only). LDM records are decompressed
  and parsed in parallel (rayon); torn or truncated records yield what decoded cleanly (`live` feeds it
  partial files). Output is float32 computed as `(raw - offset) / scale`, so float16 files match the old
  numpy pipeline bit for bit.
- `nexrad/src/chunks.rs` – real-time chunks bucket: locate newest volume in the 1..999 ring, list/fetch chunks,
  `live()`. Reused ring directories keep the previous trip's chunks; always key on the newest timestamp prefix.
- `nexrad/src/archive.rs` – archive mirror keys (`key_time`, `latest_key`, `key_at`, `keys_between`, `download`)
  and the `Bucket` trait (S3 listing + get) that `net.rs` implements with ureq and `archive::fakes::FakeBucket`
  fakes in tests.
- `nexrad/src/dealias.rs` – region-based velocity dealiasing (Py-ART-style; the whole decode + dealias + VAD +
  write pipeline takes ~0.45 s/volume):
  label same-band regions with a vectorised union-find, merge along the longest boundaries, skip
  ambiguous boundaries (mean jump ≈ Vn), then pick each component's absolute fold by agreement with the
  tilt below (`dealias_volume` goes bottom-up; the lowest tilt uses "most gates unchanged").
  Weak spots: violent-storm cores aloft and isolated small echoes can still come out one fold off.
- `nexrad/src/vad.rs` – VAD wind profile: per 1 km ring (5–60 km slant range, tilts ≤ 20°) least-squares fit of
  [1, sin, cos] to DVEL, then refit on raw VEL unfolded against that fit (immune to dealias errors); rings
  need 25 % coverage, samples in all 8 sectors, rms ≤ 4.5 m/s; median per 250 m height bin. `bunkers()`
  = Bunkers right/left mover + 0–1/0–3 km SRH, only when the profile spans ≤ 1 km to ≥ 5 km AGL
  (clear-air-only volumes often top out ~3 km and get none).
- `nexrad/src/synth.rs` – test data: `encode_archive()` (inverse of the decoder, both layouts, with a metadata
  record and signed LDM lengths like real files; `ldm_records()` splits it into chunk-sized pieces), a small
  xoshiro `Rng` (deterministic on every platform), and `Scene`, a storm (REF core, rotation couplet, debris RHO
  dip, range-folded sector) drifting in a veering wind, rendered for any site/time/scan and aliased at the
  scene's Nyquist. `build_fixtures()` writes KTST ×2 (5 min apart, split cut + SAILS repeat, 0.5°/1° bins,
  Bunkers storm motion) and a KTSU mosaic neighbour through the real encode → decode → `write_volume` path.
  Deterministic; generated (gitignored), not committed.
- Rust tests (`cargo test`): decoder round trips (both layouts, partial/torn/overflow/garbage input), dealias
  and VAD (the synthetic self-tests, plus DVEL and the VAD profile scored against the scene's unaliased
  truth), chunk ring and `live()` against a fake bucket, archive key selection, `write_volume` layout/values,
  the fixture set. No network.
- `tests/run.gd` – Godot unit tests: every `test_*` method of `tests/unit/test_*.gd` (which extend
  `tests/test_case.gd`: `check()`, `check_eq()`, `note()`, `lib`, `fixtures`) against the fixture volumes by default
  (`volumes=` for real data; fixture-only assertions are gated on `fixtures`). Exits 1 on any failure or no volumes.
- `nexrad/src/basemap.rs` – Census 1:500k state/county shapefiles (own zip + shapefile reader) + Natural Earth cities.
- `nexrad/src/volume.rs` – the on-disk format Godot reads: `rasterise()` bins radials, `write_volume()` (+
  `add_dealiased()` for DVEL, VAD winds), `read_meta`/`read_field`, `add_winds()`. `grid.rs` is the polar
  float32 grid; `time.rs` the UTC/Julian/ISO conversions (no chrono).
- `nexrad/src/main.rs` – CLI (hand-rolled args, same subcommands and stdout/stderr protocol the fetch panel
  parses). `data/` and `tests/` resolve under `$DROPLET_ROOT`, else the current directory.
- `data/raw/` – downloaded archive files (gitignored). `data/volumes/` – decoded, `data/basemap/` – basemap buffers (all gitignored).
- `scripts/volume_source.gd` – where volumes come from: `names()`, `read_meta()`, `version()` (changes when volume.json
  is rewritten), `read_file()` / `read_half()` (thread-safe; preload workers call them). `DirSource` = a directory
  (`data/volumes`, or `volumes=`); `MemorySource` = volumes handed over whole (`add_volume(name, json, {file: bytes})`,
  the shape nexrad-wasm's `decode()` returns; the web backing store). Nothing else touches volume files.
  Volumes are identified by name (`ICAO_YYYYMMDD_HHMMSS`) everywhere, not by path.
- `scripts/radar_library.gd` – indexes a `VolumeSource`, per-site lists, sequences (split at >30 min gaps); `open(name)`.
- `scripts/radar_volume.gd` – one volume, lazy float16 textures; `tilts(field)` = one sweep per
  elevation (split cuts / SAILS repeats merged, most gates then latest wins). Use tilts, not raw sweep indices.
- `scripts/volume_cache.gd` – LRU of volumes by texture bytes (1 GiB), reloads partial volumes when volume.json changes.
  `prefetch()` reads sweep files into Images on WorkerThreadPool; `poll()` (every frame) uploads ≤24 MB of
  textures; `get_volume()` waits for that volume's pending jobs. On-screen volumes are pinned.
  `main._preload_ahead()` prefetches what the active view needs (`Need`: nearest tilt / all tilts / tilt array)
  for the loop frames after the playhead (+ mosaic neighbours) up to 80 % of
  the budget, so loops bigger than the cache still stream as a rolling window. `prefetch=0` disables it.
- `scripts/main.gd` – controller: site, frame, field, *target elevation* (kept across frames), playback,
  live, mosaic neighbours. Parses `key=value` user args (see its header) – screenshot.gd passes them through.
- `scripts/hud.gd` – code-built UI (no keyboard focus except the fetch panel's text fields, so shortcuts work).
  Responsive: stretch `canvas_items` + aspect `expand` from 1280x800; `main._fit_ui_scale()` keeps the scale
  ≥ the screen scale (× `ui_scale=`) so small windows reflow instead of shrinking; `Hud._layout()` wraps the
  top-right rows, sizes/places hodograph + section (side by side when they don't stack) and wraps/hides the hint.
- `scripts/ppi_view.gd` + `shaders/ppi.gdshader` – 2D plan view, basemap, rings, decluttered city labels.
- `scripts/volume_view_3d.gd`, `scripts/cone_set.gd` + `shaders/cone.gdshader` – 3D: each tilt is a shared
  unit grid bent along the beam in the vertex shader (4/3 earth radius, vertical exaggeration); per-field
  display threshold; `scripts/orbit_camera.gd`.
- `scripts/volume_render.gd` + `shaders/volume.gdshader` + `scripts/tilt_array.gd` – 3D volume rendering (B,
  `render=volume`, opacity `-`/`=` or `density=`): a box ray-marched front to back (192 jittered steps, early
  exit), each sample → elevation/slant range (same inversion as section.gdshader) → the two bracketing tilts
  of a `TiltArray` (all tilts in one Texture2DArray, padded to the widest tilt × 720 rows; layer found via a
  0.25° LUT), opacity from the value above the display threshold. One per mosaic site, same nearest-radar
  discard. Prefetch builds the arrays on workers (`VolumeCache.Need.TILT_ARRAY`).
- `scripts/section_view.gd` + `shaders/section.gdshader` – vertical cross-section panel (X, or `section=ax,ay,bx,by`;
  left drag A→B in 2D, right drag pans). One full-plot ColorRect per elevation band; the shader inverts the
  4/3-earth beam model (pixel height/distance → elevation angle + slant range) and samples the polar
  textures directly. Default interpolates linearly between adjacent tilts; "Beams only" shows each tilt
  ±½ beamwidth (0.95°). `beam_height()` is the CPU twin, checked against cone.gdshader in tests/unit/test_geometry.gd.
- `shaders/storm.gdshaderinc` – storm-relative velocity: `storm_motion` uniform (m/s east/north, radar-local),
  subtracts its radial component × cos(elev). Included by ppi, cone, section and volume shaders. `main._storm_vector()`
  is non-zero only for VEL/DVEL with SRM on (T, HUD row, `srm=from_deg,speed_ms` or `srm=auto`, meteorological
  "from"). Auto (default) = Bunkers RM from `RadarLibrary.storm_motion_near()`: this volume's, else the same
  site's nearest within 60 min, else another site's (used unrotated); nudging < > - + switches to manual.
  mosaic neighbours get it rotated into their frame (`storm_motion.rotated(rotation)`).
- `scripts/fetcher.gd` + `scripts/fetch_panel.gd` – fetch from the UI (F): runs `nexrad update|live` (the binary
  from `DROPLET_NEXRAD`, else PATH) via `OS.execute_with_pipe` (non-blocking), sets `DROPLET_ROOT` to the
  project, parses `[i/n]` progress and
  volume names (`ICAO_YYYYMMDD_HHMMSS`) from its output. On web each job is a `web/nexrad_worker.js` Worker
  (JavaScriptBridge; stop = terminate) and decoded volumes arrive through `volume_received` into main's
  MemorySource. New volumes are rescanned immediately; a finished
  update jumps to its last volume, a live job takes over the view on its first volume. Processes are killed
  on exit. The fetch panel's LineEdits are the only focusable controls (focus released on close).
- `scripts/app_options.gd` – `key=value` options from the command line, or the query string on web;
  `fetch=` (and on web, any URL without it: the volume at `time=`, else live) starts a job at startup.
  On web main.gd uses a MemorySource (900 MB budget, oldest evicted; the heap caps at 2 GB) and a 384 MB texture cache.
- `scripts/basemap.gd` + `shaders/basemap*.gdshader*` – lon/lat line meshes projected on the GPU
  (azimuthal equidistant around the site, haversine form for float32); `Basemap.project()` is the CPU twin.
- `scripts/hodograph.gd` – HUD hodograph (W): VAD profile coloured 0–1/1–3/3–6/6+ km, RM/LM, mean wind,
  the storm motion in use (×), SRH.
- `scripts/wind_profile_view.gd` – VWP (P): each loop volume's `wind_profile` as a column of wind barbs (kt,
  coloured by speed) over time, bottom left; rows/columns thin out to fit, the current column is highlighted,
  clicking one jumps there (`frame_picked`).
- Hover readout: `main._update_readout()` (every frame, recomputed only when its inputs change) picks the
  section panel (`SectionView.sample_at`, CPU twin of section.gdshader), the VWP (`sample_at`) or the 2D map
  (`main._readout_2d`: nearest radar as in the mosaic shaders, value + range/bearing + beam height + lat/lon
  via `Basemap.unproject`). Values come from `RadarVolume.value_at()`, which reads 2 bytes of the sweep file via `VolumeSource.read_half()`
  (no texture needed); `RadarVolume.storm_relative()` is the CPU twin of storm.gdshaderinc. Hovering the section
  marks the point on the A-B line in 2D. Not in 3D. `hover=x,y` pins it (canvas units) for screenshots.
- `scripts/colormaps.gd` – per-field value ranges, units and gradient textures.
- `nexrad/`, `data/` and `tests/fixtures/` carry a `.gdignore` so the editor does not try to import them; `res://data/...` is still readable via FileAccess in dev builds. Exported builds will need `user://`.

## Data format (format_version 1)

`data/volumes/<ICAO>_<YYYYMMDD_HHMMSS>/volume.json` + one `sNN_<FIELD>.bin` per sweep/field.

- `.bin` = little-endian float16, row-major `[azimuth_bin][gate]`, bin `b` covers `[b*step, (b+1)*step)` degrees clockwise from north (step 0.5° → 720 rows, 1° → 360 rows). Loads directly as `Image.FORMAT_RH`, width = gates.
- Sentinels: `-1000` missing/below threshold, `-2000` range folded. Shader discards `< -900`, paints purple `< -1500`.
- Per field: `n_gates`, `first_gate_m` (range to centre of gate 0), `gate_spacing_m`. Fields on the same sweep can differ (REF often 1832 gates, others 1192).
- Split-cut VCPs produce two sweeps at ~the same elevation: a surveillance cut (REF/ZDR/PHI/RHO/CFP) and a Doppler cut (REF/VEL/SW). `RadarVolume.tilts()` / `tilt_near()` pick one sweep per elevation that has the requested field.
- `DVEL` = dealiased `VEL`, written next to every VEL sweep with the same geometry (VEL stays raw).
  Volumes decoded before it existed (e.g. old `live` output with no raw file) simply lack it.
- `wind_profile` = `{height_m, u_ms, v_ms, n}` (parallel lists, m above the radar, m/s east/north) or null;
  `storm_motion` = `{method, right, left, mean_0_6km, shear_0_6km: [u, v], srh_0_1km, srh_0_3km}` or null
  (nexrad/src/vad.rs). Added without a format_version bump; older volume.json lacks them (`nexrad winds`).
- `complete: false` marks a partial volume still being filled by `live`. Files are written via atomic rename so Godot never reads a torn file; `main.gd` re-scans every 3 s while live.

## Mosaic

Other sites' volumes within 10 min of the current one are placed at `Basemap.project(site)` and
rotated for meridian convergence. Nearest-radar compositing: each ppi/cone shader gets the other
radars' positions in its local frame (+x east, +y south) and discards pixels closer to another radar.

## Conventions

- World units in Godot are **kilometres**, +x east, -y north (screen down). Camera2D zoom = px/km.
- GDScript formatted with `gdformat`, lint-clean with `gdlint` (tabs, typed vars, `class_name` on shared scripts).
- Rust: `cargo fmt` (rustfmt.toml, 140 columns) and `cargo clippy --all-targets` clean. Pure-Rust dependencies only
  (bzip2, flate2, half, rayon, serde/serde_json, ureq) so the crate also compiles to wasm; keep networking behind
  the `native` feature. Output must stay bit-identical to what the volume tests pin (float32 arithmetic order matters).
- Commit signing is disabled for this repo (local git config). Do not re-enable.
- Don't commit anything under `data/`.

## Known limits / next steps

- Decoder reads both archive layouts: bzip2 LDM records (current) and the older gzip-wrapped uncompressed stream (~pre-2016, `.gz` keys). Only Message 31 radials are parsed (Build 10+, ~mid-2008 onward); pre-2008 files use Message 1 and would need a separate parser.
- Verified against KTLX 2026-09-22 (VCP 212, bz2) and KTLX 2013-05-20 20:03Z (VCP 12, gz, the Moore tornado).
- `live` starts on the in-progress volume (skipping it if joined after its first chunk), then follows each new one. It bootstraps by probing ~20 S3 listings to find the newest volume number; could cache the last number in `data/`.
- Done: time animation + live following, 3D cones, basemap, site picker, multi-site mosaic,
  background prefetch of loop frames, velocity dealiasing (DVEL), vertical cross-sections,
  storm-relative velocity, fetching from the UI, translucent volume rendering, VAD wind profile +
  hodograph + automatic (Bunkers) storm motion, hover readout (2D, section, VWP), VWP time-height plot.
- Next ideas: dealiasing that uses the
  previous volume as a temporal reference, the A-B section line drawn in 3D, mosaic cross-sections,
  a hover readout in 3D (pick against the cones), a VAD-based temporal reference for dealiasing.
- Web: no basemap yet (res://data is not exported), and decoded volumes are not persisted (raw files are, in
  the Cache API; re-decoding costs ~0.5 s/volume against 84 MB stored per decoded volume).
- Mosaic uses whatever is on disk; `live` follows one site per process (the fetch panel can start several
  for a live mosaic). Fetching from the UI needs the `nexrad` binary (PATH or `DROPLET_NEXRAD`) and a source checkout (not an export).
- The 3D ground disk/rings are centred on the selected site only.
- Cross-sections use the selected site only (no mosaic), and the A-B line is not drawn in 3D.
