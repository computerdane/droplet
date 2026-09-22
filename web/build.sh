#!/usr/bin/env bash
# Builds the static web app into OUT_DIR (default export/web): Godot's web export plus the
# nexrad-wasm decoder and web/nexrad_worker.js next to index.html. Run from the dev shell.
# Serve it with the cross-origin isolation headers threads need: node web/serve.mjs OUT_DIR
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-export/web}"
# export_presets.cfg is gitignored (the editor rewrites it); seed it from the committed copy.
[ -f export_presets.cfg ] || cp web/export_presets.template.cfg export_presets.cfg
nexrad-wasm/build.sh
mkdir -p "$out"
godot --headless --path . --import >/dev/null
godot --headless --path . --export-release Web "$(realpath "$out")/index.html"
cp nexrad-wasm/pkg/nexrad_wasm.js nexrad-wasm/pkg/nexrad_wasm_bg.wasm web/nexrad_worker.js "$out/"
ls -l "$out"
