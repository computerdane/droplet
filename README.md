# droplet

A weather radar visualizer built with Godot. Live NEXRAD data seconds behind real time,
plus history browsing back to 2008.

## Development

```sh
nix develop                     # or `direnv allow` once
python -m nexrad update KTLX    # fetch + decode the newest volume for a site
godot                           # run
```

Controls: Up/Down sweep · Left/Right volume · L live/history · 1-7 field (REF VEL SW ZDR PHI RHO CFP) · wheel zoom · drag pan · Home reset.

For real-time data run `python -m nexrad live KTLX` in another terminal; the app follows it.
See `CLAUDE.md` for architecture and data format.
