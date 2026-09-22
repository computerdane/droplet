extends "res://tests/test_case.gd"
## Sweep textures, colormaps, the hover readout's file reads and background loading.

const RadarVolumeScript := preload("res://scripts/radar_volume.gd")
const ColormapsScript := preload("res://scripts/colormaps.gd")
const VolumeCacheScript := preload("res://scripts/volume_cache.gd")


## One texture per field of sweep 0, sized gates x azimuth bins, and a colormap for each.
func test_textures() -> void:
	var vol = RadarVolumeScript.load_from_dir(lib.latest())
	for f in vol.fields_of(0):
		var tex = vol.get_texture(0, f)
		if not check(tex != null, "sweep 0 %s texture" % f):
			continue
		var fd: Dictionary = vol.sweep(0)["fields"][f]
		check_eq(tex.get_width(), int(fd["n_gates"]), "%s width" % f)
		check_eq(tex.get_height(), int(vol.sweep(0)["n_azimuth_bins"]), "%s height" % f)
		check(ColormapsScript.texture_for(f) != null, "%s colormap" % f)


## The readout reads single gates from the sweep files; they must match the texels the shaders
## sample (same gate rounding and azimuth bin).
func test_readout() -> void:
	var vol = RadarVolumeScript.load_from_dir(lib.volumes[0])
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var bad := 0
	var checked := 0
	for f in ["REF", "VEL"]:
		for i in vol.tilts(f):
			var img: Image = vol.read_image(i, f)
			var fd: Dictionary = vol.sweep(i)["fields"][f]
			var first := float(fd["first_gate_m"]) / 1000.0
			var step := float(fd["gate_spacing_m"]) / 1000.0
			for k in 20:
				var gate := rng.randi_range(0, img.get_width() - 1)
				var row := rng.randi_range(0, img.get_height() - 1)
				# A point inside the texel, off its centre.
				var r := first + (gate + rng.randf_range(-0.45, 0.45)) * step
				var az := (row + rng.randf_range(0.05, 0.95)) * 360.0 / img.get_height()
				var want := img.get_pixel(gate, row).r
				var got: float = vol.value_at(i, f, az, r)
				checked += 1
				if absf(got - want) > 1e-3:
					bad += 1
	check(bad == 0, "value_at: %d of %d gates differ from the images" % [bad, checked])


## Background loading: prefetch the REF tilts of up to three complete volumes, drain the jobs
## with poll() and check every texture arrived; get_volume() must finish a pending job itself.
## Then one field as a Texture2DArray for volume rendering, also built on a worker.
func test_preload() -> void:
	var cache = VolumeCacheScript.new()
	var paths: Array[String] = []
	for p in lib.volumes:
		if paths.size() < 3 and RadarVolumeScript.load_from_dir(p).is_complete():
			paths.append(p)
	if not check(not paths.is_empty(), "a complete volume"):
		return
	var expected := 0
	for p in paths:
		expected += cache.prefetch(p, "REF", 0.5, VolumeCacheScript.Need.ALL_TILTS)
	var waited = cache.get_volume(paths[0])
	check(waited.texture_bytes > 0, "get_volume() finished its pending job")
	var deadline := Time.get_ticks_msec() + 20000
	_drain(cache, deadline)
	check_eq(cache.pending_jobs(), 0, "pending jobs")
	check_eq(cache.used_bytes(), expected, "bytes loaded")
	for p in paths:
		var v = cache.get_volume(p)
		for i in v.tilts("REF"):
			check(v.has_texture(i, "REF"), "%s sweep %d REF loaded" % [p.get_file(), i])
	var p: String = paths[-1]
	cache.prefetch(p, "VEL", 0.5, VolumeCacheScript.Need.TILT_ARRAY)
	_drain(cache, deadline)
	var va = cache.get_volume(p)
	var ta = va.tilt_arrays.get("VEL")
	if check(ta != null, "VEL tilt array built"):
		check_eq(ta.texture.get_layers(), va.tilts("VEL").size(), "tilt array layers")


func _drain(cache, deadline: int) -> void:
	while cache.pending_jobs() > 0 and Time.get_ticks_msec() < deadline:
		cache.poll()
		OS.delay_msec(2)
