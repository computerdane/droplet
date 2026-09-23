#!/usr/bin/env bash
# Builds the static web app into OUT_DIR (default export/web): Godot's web export plus the
# nexrad-wasm decoder and web/nexrad_worker.js next to index.html. Run from the dev shell.
# Serve it with the cross-origin isolation headers threads need: node web/serve.mjs OUT_DIR
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-export/web}"
# Smoke screenshots and prior exports are build products, not project resources.
mkdir -p export
touch export/.gdignore
# export_presets.cfg is gitignored (the editor rewrites it); seed it from the committed copy.
[ -f export_presets.cfg ] || cp web/export_presets.template.cfg export_presets.cfg
# Godot only looks for export templates under its data dir; link the flake's there (CI, fresh machines).
templates="${XDG_DATA_HOME:-$HOME/.local/share}/godot/export_templates"
for t in "${GODOT_EXPORT_TEMPLATES:?run from the dev shell}"/*; do
  [ -e "$templates/$(basename "$t")" ] || { mkdir -p "$templates" && ln -s "$t" "$templates/"; }
done
nexrad-wasm/build.sh
mkdir -p "$out"
touch "$out/.gdignore" # keep the editor from importing the export (and packing it)
godot --headless --path . --import >/dev/null
godot --headless --path . --export-release Web "$(realpath "$out")/index.html"
node web/prepare_export.mjs "$out"
cp nexrad-wasm/pkg/nexrad_wasm.js nexrad-wasm/pkg/nexrad_wasm_bg.wasm web/nexrad_worker.js "$out/"
# The page downloads the basemap in the background (scripts/basemap.gd); build it with `nexrad basemap`.
if [ -f data/basemap/basemap.json ]; then
  mkdir -p "$out/basemap" && cp data/basemap/basemap.json data/basemap/*.bin "$out/basemap/"
else
  echo "no data/basemap (run: nexrad basemap); the page will have no map lines" >&2
fi
ls -l "$out"
