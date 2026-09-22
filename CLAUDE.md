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
godot --editor                                      # open project
godot                                               # run main scene
godot --headless --path . --import                  # (re)build .godot/ cache after adding scripts/scenes
godot --headless --path . --script res://tests/smoke.gd
gdformat scripts tests && gdlint scripts tests
```

## Layout

- `nexrad/level2.py` – Archive2 / Message 31 decoder (numpy + bz2 only; no MetPy/Py-ART since neither is in nixpkgs).
- `nexrad/chunks.py` – real-time chunks bucket: locate newest volume in the 1..999 ring, list/fetch chunks.
- `nexrad/__main__.py` – CLI; `write_volume()` defines the on-disk format Godot reads.
- `data/raw/` – downloaded archive files (gitignored). `data/volumes/` – decoded (gitignored).
- `scripts/radar_library.gd` – indexes `data/volumes`; `scripts/radar_volume.gd` – loads one volume, lazy float16 textures.
- `scripts/colormaps.gd` – per-field value ranges and gradient textures.
- `shaders/ppi.gdshader` – polar → cartesian lookup on a quad; `scenes/main.tscn` + `scripts/main.gd` – controls, HUD, live/history.
- `nexrad/` and `data/` carry a `.gdignore` so the editor does not try to import them; `res://data/...` is still readable via FileAccess in dev builds. Exported builds will need `user://`.

## Data format (format_version 1)

`data/volumes/<ICAO>_<YYYYMMDD_HHMMSS>/volume.json` + one `sNN_<FIELD>.bin` per sweep/field.

- `.bin` = little-endian float16, row-major `[azimuth_bin][gate]`, bin `b` covers `[b*step, (b+1)*step)` degrees clockwise from north (step 0.5° → 720 rows, 1° → 360 rows). Loads directly as `Image.FORMAT_RH`, width = gates.
- Sentinels: `-1000` missing/below threshold, `-2000` range folded. Shader discards `< -900`, paints purple `< -1500`.
- Per field: `n_gates`, `first_gate_m` (range to centre of gate 0), `gate_spacing_m`. Fields on the same sweep can differ (REF often 1832 gates, others 1192).
- Split-cut VCPs produce two sweeps at ~the same elevation: a surveillance cut (REF/ZDR/PHI/RHO/CFP) and a Doppler cut (REF/VEL/SW). `RadarVolume.nearest_sweep_with()` handles picking a sweep that has the requested field.
- `complete: false` marks a partial volume still being filled by `live`. Files are written via atomic rename so Godot never reads a torn file; `main.gd` re-scans every 3 s while live.

## Conventions

- World units in Godot are **kilometres**, +x east, -y north (screen down). Camera2D zoom = px/km.
- GDScript formatted with `gdformat`, lint-clean with `gdlint` (tabs, typed vars, `class_name` on shared scripts).
- Python: stdlib + numpy + requests only; keep the decoder dependency-free so the flake stays simple.
- Commit signing is disabled for this repo (local git config). Do not re-enable.
- Don't commit anything under `data/`.

## Known limits / next steps

- Decoder reads both archive layouts: bzip2 LDM records (current) and the older gzip-wrapped uncompressed stream (~pre-2016, `.gz` keys). Only Message 31 radials are parsed (Build 10+, ~mid-2008 onward); pre-2008 files use Message 1 and would need a separate parser.
- Verified against KTLX 2026-09-22 (VCP 212, bz2) and KTLX 2013-05-20 20:03Z (VCP 12, gz, the Moore tornado).
- `live` joins mid-volume on start (partial volume marked `complete: false`), then follows each new one. It bootstraps by probing ~20 S3 listings to find the newest volume number; could cache the last number in `data/`.
- Current render is a single 2D PPI. Planned: 3D cone/volume rendering of all sweeps (the polar textures map naturally onto cones at each elevation), time animation across volumes, map/basemap underlay via lat/lon → local km projection (site lat/lon is in `volume.json`), velocity dealiasing, storm-relative motion, cross-sections.
- Multiple sites: library groups by ICAO but the UI only follows the newest volume overall; add a site picker.
