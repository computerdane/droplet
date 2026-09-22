extends SceneTree
## Headless smoke test: godot --headless --path . --script res://tests/smoke.gd
## Loads the newest decoded volume and builds one texture per field of sweep 0.

const RadarLibraryScript := preload("res://scripts/radar_library.gd")
const RadarVolumeScript := preload("res://scripts/radar_volume.gd")
const ColormapsScript := preload("res://scripts/colormaps.gd")


func _initialize() -> void:
	var lib = RadarLibraryScript.new()
	print("volumes: ", lib.volumes.size(), "  sites: ", lib.sites())
	if lib.volumes.is_empty():
		push_error("no volumes under %s" % lib.root)
		quit(1)
		return
	var vol = RadarVolumeScript.load_from_dir(lib.latest())
	if vol == null:
		quit(1)
		return
	print(
		(
			"%s %s vcp=%d sweeps=%d complete=%s"
			% [
				vol.icao(),
				vol.time_utc(),
				int(vol.meta.get("vcp", 0)),
				vol.sweep_count(),
				vol.is_complete()
			]
		)
	)
	var failed := false
	for f in vol.fields_of(0):
		var tex = vol.get_texture(0, f)
		if tex == null:
			failed = true
			continue
		var cmap = ColormapsScript.texture_for(f)
		print(
			(
				"  sweep0 %-3s %dx%d  cmap %d px  range %s"
				% [
					f,
					tex.get_width(),
					tex.get_height(),
					cmap.get_width(),
					ColormapsScript.range_of(f)
				]
			)
		)
	quit(1 if failed else 0)
