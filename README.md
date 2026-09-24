# droplet

A weather radar visualizer built with Godot. Live NEXRAD data seconds behind real time,
plus history browsing back to the early 1990s.

## Try Droplet

[Open the live web app](https://computerdane.github.io/droplet/) in your browser, or run the
desktop app (Linux or Apple Silicon macOS) from
[this GitHub repository](https://github.com/computerdane/droplet) with Nix, without cloning it:

```sh
nix run github:computerdane/droplet
```

Explore notable events. Each link loads a radar loop and opens at the event peak:

- [Bridge Creek–Moore F5 (1999)](https://computerdane.github.io/droplet/?event=moore1999) · Desktop: `nix run github:computerdane/droplet -- -- event=moore1999`
- [Moore EF5 (2013)](https://computerdane.github.io/droplet/?event=moore2013) · Desktop: `nix run github:computerdane/droplet -- -- event=moore2013`
- [Joplin EF5 (2011)](https://computerdane.github.io/droplet/?event=joplin2011) · Desktop: `nix run github:computerdane/droplet -- -- event=joplin2011`
- [Hurricane Katrina (2005)](https://computerdane.github.io/droplet/?event=katrina2005) · Desktop: `nix run github:computerdane/droplet -- -- event=katrina2005`

## Desktop package (Linux / macOS)

From a checkout, run `nix run`. Nix builds the app and decoder and bundles the
basemap; no dev shell or manual data setup is needed. Click a radar to follow it live.

```sh
nix run
nix run . -- -- site=KTLX fetch=live
nix build                       # result/bin/droplet
nix profile add .#droplet       # install droplet (and on Linux, its desktop menu entry)
```

Downloaded scans live in `${XDG_CACHE_HOME:-~/.cache}/droplet/data`, with the
decoder's default 20 GB quota (`DROPLET_QUOTA_GB` overrides it). Saved animations
live in `${XDG_DATA_HOME:-~/.local/share}/droplet/exports`. On macOS the fallbacks
are `~/Library/Caches` and `~/Library/Application Support` instead. Set `DROPLET_ROOT` to
override the cache root, or `DROPLET_EXPORT_DIR` to change the export directory.
The basemap is pinned by hash and updated with the package, not at launch.

macOS support covers Apple Silicon (`aarch64-darwin`); nixpkgs no longer builds for
Intel Macs. Godot comes prebuilt from the Nix binary cache and runs as a plain
executable from the Nix store (not quarantined, so Gatekeeper should not prompt); no
app is added to /Applications. The
macOS dev shell omits the Linux-only golden-screenshot (Xvfb/Mesa) and Chromium tools.

The decoder is also available separately: `nix run .#nexrad -- update KTLX`.
When run separately it writes under the current directory unless `DROPLET_ROOT`
is set. For NixOS or Home Manager, add this flake's `packages.${system}.droplet`
to `environment.systemPackages` or `home.packages`.

## Development

```sh
nix develop                     # or `direnv allow` once
cargo build --release          # the nexrad CLI (on PATH in the dev shell)
nexrad update KTLX             # fetch + decode the newest volume for a site
nexrad basemap                 # once: state/county lines and city labels
godot                          # run
```

A good demo: `nexrad update KTLX --from 2013-05-20T19:30Z --to 2013-05-20T20:40Z`
(the Moore, OK tornado), the same for KINX and KFDR, then press Space, V and M. Or press F
in the app to fetch a site, a time or a time range (or follow a site live) from the UI.

Controls: Space play/pause · Left/Right step volume · Home/End first/last · `[` `]` speed ·
L live · Up/Down tilt · 1-8 field (REF VEL SW ZDR PHI RHO CFP DVEL) · 9 column products
(composite reflectivity, echo tops, VIL, low-level rotation, rotation tracks) · 0 KDP, azimuthal
shear, hydrometeor classes · S next site · M mosaic · V 2D/3D · R reset view · X cross-section ·
T storm-relative velocity · W hodograph · P wind profile over the loop (VWP; click a column to
jump there) · A warnings · C storm cells · O SPC outlook · E export the loop (animated PNG) · F fetch ·
H show all keys in the bottom-left hint (it shows the essentials by default).
2D: wheel zoom, drag pan; in cross-section mode left drag draws the line A→B, right drag pans.
Hovering the map, the cross-section or the VWP shows the value under the mouse.
3D: left drag orbit, right drag pan, wheel zoom, B cones/volume rendering, I isolate tilts,
`,` `.` display threshold, `-` `=` volume opacity, PgUp/PgDn height exaggeration.
The buttons at the top right and the playback bar do the same with the mouse.

DVEL is VEL dealiased at decode time; storm motion for storm-relative velocity is set with the
row under the field buttons. For real-time data, run `nexrad live KTLX` in another
terminal (or use F → Live); the app follows it. See [the architecture guide](docs/architecture.md) for architecture and data format.

## AI development workflow

Start an interactive coordinator with `bash tools/automation/start` for Codex or
`bash tools/automation/start claude` for Claude Code. Either coordinator watches
GitHub, answers questions, and delegates approved work in parallel. Run only one
coordinator in a checkout; stop and checkpoint before switching between them.
Approve an issue with an unedited `/approve` comment; use `/hold` to stop it.
Changes arrive in PRs with CI and Pages previews, with native GitHub stacks for
dependent changes. You control merging.

See [setup and operation](docs/development-loop.md) for bot authentication, approval,
recovery, and model routing, and [Pages previews](docs/pages-previews.md) for deployment.

## Web

```sh
web/build.sh                   # Godot web export + the wasm decoder -> export/web/
node web/serve.mjs             # http://127.0.0.1:8060/ with the isolation headers threads need
```

Everything runs in the browser: a Web Worker fetches archive files or live chunks straight from
Unidata's public buckets and decodes them with the same Rust code compiled to WebAssembly.
The query string takes the same options as the command line, and a URL fetches what it points
at, so links are permalinks: `?site=KTLX&time=20130520_200359` (the Moore tornado),
`?site=KTLX&fetch=2013-05-20T19:30Z/2013-05-20T20:40Z&play=1` (a loop), `?site=KTLX` (live).
