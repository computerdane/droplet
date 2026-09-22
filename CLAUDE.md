# droplet

Weather radar visualizer. Godot 4.7 renders NEXRAD Level II data; a small Python
sidecar (`nexrad/`) fetches and decodes it. Everything runs from the Nix dev shell
(`nix develop`, or direnv). Godot, gdformat/gdlint, python+numpy+requests are all provided.

Goals: **live** view that is never behind (seconds, via the real-time chunks bucket) and
**history** browsing of any volume back to ~2008 (via the archive mirror), with visualizations
that go well beyond a flat reflectivity map.

## Commands

```sh
python -m nexrad update KTLX                        # newest archive volume -> data/volumes/
python -m nexrad update KTLX --at 2013-05-20T20:00Z # historical volume (Moore, OK tornado)
python -m nexrad update KTLX --from ... --to ...    # a range of volumes
python -m nexrad live KTLX                          # poll chunks bucket, rewrite partial volume as it grows
python -m nexrad basemap                            # once: Census states/counties + cities -> data/basemap/
python -m nexrad decode data/raw/*_V06*             # re-decode everything (e.g. after decoder/dealias changes)
python -m nexrad.dealias                            # dealiaser self-test on a synthetic aliased sweep
godot --editor                                      # open project
godot                                               # run main scene
godot --headless --path . --import                  # (re)build .godot/ cache after adding scripts/scenes
godot --headless --path . --script res://tests/smoke.gd
godot --path . --script res://tests/screenshot.gd -- out.png time=20130520_200359 view=3d mosaic=1
godot --path . --script res://tests/frametimes.gd -- frames=1500 view=3d mosaic=1 play=1 fps=15 time=20130520_193407
gdformat scripts tests && gdlint scripts tests
```

## Layout

- `nexrad/level2.py` – Archive2 / Message 31 decoder (numpy + bz2 only; no MetPy/Py-ART since neither is in nixpkgs).
- `nexrad/chunks.py` – real-time chunks bucket: locate newest volume in the 1..999 ring, list/fetch chunks.
  Reused ring directories keep the previous trip's chunks; always key on the newest timestamp prefix.
- `nexrad/dealias.py` – region-based velocity dealiasing (Py-ART-style, numpy only, ~0.5 s/volume):
  label same-band regions with a vectorised union-find, merge along the longest boundaries, skip
  ambiguous boundaries (mean jump ≈ Vn), then pick each component's absolute fold by agreement with the
  tilt below (`dealias_volume` goes bottom-up; the lowest tilt uses "most gates unchanged").
  Weak spots: violent-storm cores aloft and isolated small echoes can still come out one fold off.
- `nexrad/basemap.py` – Census 1:500k state/county shapefiles (stdlib reader) + Natural Earth cities.
- `nexrad/__main__.py` – CLI; `write_volume()` defines the on-disk format Godot reads; `add_dealiased()` adds DVEL.
- `data/raw/` – downloaded archive files (gitignored). `data/volumes/` – decoded, `data/basemap/` – basemap buffers (all gitignored).
- `scripts/radar_library.gd` – indexes `data/volumes`, per-site lists, sequences (split at >30 min gaps).
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
- `scripts/hud.gd` – code-built UI (no keyboard focus anywhere, so shortcuts always work).
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
  ±½ beamwidth (0.95°). `beam_height()` is the CPU twin, checked against cone.gdshader in smoke.gd.
- `shaders/storm.gdshaderinc` – storm-relative velocity: `storm_motion` uniform (m/s east/north, radar-local),
  subtracts its radial component × cos(elev). Included by ppi, cone and section shaders. `main._storm_vector()`
  is non-zero only for VEL/DVEL with SRM on (T, HUD row, `srm=from_deg,speed_ms`, meteorological "from");
  mosaic neighbours get it rotated into their frame (`storm_motion.rotated(rotation)`).
- `scripts/fetcher.gd` + `scripts/fetch_panel.gd` – fetch from the UI (F): runs `python -u -m nexrad update|live`
  via `OS.execute_with_pipe` (non-blocking), sets PYTHONPATH to the project, parses `[i/n]` progress and
  volume names (`ICAO_YYYYMMDD_HHMMSS`) from its output. New volumes are rescanned immediately; a finished
  update jumps to its last volume, a live job takes over the view on its first volume. Processes are killed
  on exit. The fetch panel's LineEdits are the only focusable controls (focus released on close).
- `scripts/basemap.gd` + `shaders/basemap*.gdshader*` – lon/lat line meshes projected on the GPU
  (azimuthal equidistant around the site, haversine form for float32); `Basemap.project()` is the CPU twin.
- `scripts/colormaps.gd` – per-field value ranges, units and gradient textures.
- `nexrad/` and `data/` carry a `.gdignore` so the editor does not try to import them; `res://data/...` is still readable via FileAccess in dev builds. Exported builds will need `user://`.

## Data format (format_version 1)

`data/volumes/<ICAO>_<YYYYMMDD_HHMMSS>/volume.json` + one `sNN_<FIELD>.bin` per sweep/field.

- `.bin` = little-endian float16, row-major `[azimuth_bin][gate]`, bin `b` covers `[b*step, (b+1)*step)` degrees clockwise from north (step 0.5° → 720 rows, 1° → 360 rows). Loads directly as `Image.FORMAT_RH`, width = gates.
- Sentinels: `-1000` missing/below threshold, `-2000` range folded. Shader discards `< -900`, paints purple `< -1500`.
- Per field: `n_gates`, `first_gate_m` (range to centre of gate 0), `gate_spacing_m`. Fields on the same sweep can differ (REF often 1832 gates, others 1192).
- Split-cut VCPs produce two sweeps at ~the same elevation: a surveillance cut (REF/ZDR/PHI/RHO/CFP) and a Doppler cut (REF/VEL/SW). `RadarVolume.tilts()` / `tilt_near()` pick one sweep per elevation that has the requested field.
- `DVEL` = dealiased `VEL`, written next to every VEL sweep with the same geometry (VEL stays raw).
  Volumes decoded before it existed (e.g. old `live` output with no raw file) simply lack it.
- `complete: false` marks a partial volume still being filled by `live`. Files are written via atomic rename so Godot never reads a torn file; `main.gd` re-scans every 3 s while live.

## Mosaic

Other sites' volumes within 10 min of the current one are placed at `Basemap.project(site)` and
rotated for meridian convergence. Nearest-radar compositing: each ppi/cone shader gets the other
radars' positions in its local frame (+x east, +y south) and discards pixels closer to another radar.

## Conventions

- World units in Godot are **kilometres**, +x east, -y north (screen down). Camera2D zoom = px/km.
- GDScript formatted with `gdformat`, lint-clean with `gdlint` (tabs, typed vars, `class_name` on shared scripts).
- Python: stdlib + numpy + requests only; keep the decoder dependency-free so the flake stays simple.
- Commit signing is disabled for this repo (local git config). Do not re-enable.
- Don't commit anything under `data/`.

## Known limits / next steps

- Decoder reads both archive layouts: bzip2 LDM records (current) and the older gzip-wrapped uncompressed stream (~pre-2016, `.gz` keys). Only Message 31 radials are parsed (Build 10+, ~mid-2008 onward); pre-2008 files use Message 1 and would need a separate parser.
- Verified against KTLX 2026-09-22 (VCP 212, bz2) and KTLX 2013-05-20 20:03Z (VCP 12, gz, the Moore tornado).
- `live` starts on the in-progress volume (skipping it if joined after its first chunk), then follows each new one. It bootstraps by probing ~20 S3 listings to find the newest volume number; could cache the last number in `data/`.
- Done: time animation + live following, 3D cones, basemap, site picker, multi-site mosaic,
  background prefetch of loop frames, velocity dealiasing (DVEL), vertical cross-sections,
  storm-relative velocity (storm motion is manual; no automatic estimate yet), fetching from the UI,
  translucent volume rendering.
- Next ideas: automatic storm motion (e.g. Bunkers from a VAD wind profile), dealiasing that uses the
  previous volume as a temporal reference, the A-B section line drawn in 3D, mosaic cross-sections,
  a hover readout (value/height) in the section panel.
- Mosaic uses whatever is on disk; `live` follows one site per process (the fetch panel can start several
  for a live mosaic). Fetching from the UI needs the dev shell's `python` and a source checkout (not an export).
- The 3D ground disk/rings are centred on the selected site only.
- Cross-sections use the selected site only (no mosaic), and the A-B line is not drawn in 3D.
