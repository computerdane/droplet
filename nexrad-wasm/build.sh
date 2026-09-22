#!/usr/bin/env bash
# Builds the browser decoder into nexrad-wasm/pkg/ (ES module + .wasm) from the dev shell.
set -euo pipefail
cd "$(dirname "$0")/.."
cargo build -p nexrad-wasm --target wasm32-unknown-unknown --release
wasm-bindgen --target web --out-dir nexrad-wasm/pkg nexrad/target/wasm32-unknown-unknown/release/nexrad_wasm.wasm
wasm-opt -O3 nexrad-wasm/pkg/nexrad_wasm_bg.wasm -o nexrad-wasm/pkg/nexrad_wasm_bg.wasm
ls -l nexrad-wasm/pkg/nexrad_wasm_bg.wasm
echo "gzipped: $(gzip -9c nexrad-wasm/pkg/nexrad_wasm_bg.wasm | wc -c) bytes"
