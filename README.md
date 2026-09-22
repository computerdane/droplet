# droplet

A weather radar visualizer built with Godot. Live NEXRAD data seconds behind real time,
plus history browsing back to 2008.

## Development

```sh
nix develop                     # or `direnv allow` once
python -m nexrad update KTLX    # fetch + decode the newest volume for a site
python -m nexrad basemap        # once: state/county lines and city labels
godot                           # run
```

A good demo: `python -m nexrad update KTLX --from 2013-05-20T19:30Z --to 2013-05-20T20:40Z`
(the Moore, OK tornado), the same for KINX and KFDR, then press Space, V and M.

Controls: Space play/pause · Left/Right step volume · Home/End first/last · `[` `]` speed ·
L live · Up/Down tilt · 1-7 field (REF VEL SW ZDR PHI RHO CFP) · S next site · M mosaic ·
V 2D/3D · R reset view. 2D: wheel zoom, drag pan. 3D: left drag orbit, right drag pan,
wheel zoom, I isolate tilts, `,` `.` display threshold, PgUp/PgDn height exaggeration.
The site picker, field buttons and playback bar do the same with the mouse.

For real-time data run `python -m nexrad live KTLX` in another terminal; the app follows it.
See `CLAUDE.md` for architecture and data format.
