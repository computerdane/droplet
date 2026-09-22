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
(the Moore, OK tornado), the same for KINX and KFDR, then press Space, V and M. Or press F
in the app to fetch a site, a time or a time range (or follow a site live) from the UI.

Controls: Space play/pause · Left/Right step volume · Home/End first/last · `[` `]` speed ·
L live · Up/Down tilt · 1-8 field (REF VEL SW ZDR PHI RHO CFP DVEL) · S next site · M mosaic ·
V 2D/3D · R reset view · X cross-section · T storm-relative velocity · W hodograph ·
P wind profile over the loop (VWP; click a column to jump there) · F fetch.
2D: wheel zoom, drag pan; in cross-section mode left drag draws the line A→B, right drag pans.
Hovering the map, the cross-section or the VWP shows the value under the mouse.
3D: left drag orbit, right drag pan, wheel zoom, B cones/volume rendering, I isolate tilts,
`,` `.` display threshold, `-` `=` volume opacity, PgUp/PgDn height exaggeration.
The buttons at the top right and the playback bar do the same with the mouse.

DVEL is VEL dealiased at decode time; storm motion for storm-relative velocity is set with the
row under the field buttons. For real-time data, run `python -m nexrad live KTLX` in another
terminal (or use F → Live); the app follows it. See `CLAUDE.md` for architecture and data format.
