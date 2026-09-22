extends "res://tests/test_case.gd"
## Sweep textures, colormaps, the hover readout's file reads and background loading.

const ColormapsScript := preload("res://scripts/colormaps.gd")
const VolumeCacheScript := preload("res://scripts/volume_cache.gd")


## One texture per field of sweep 0, sized gates x azimuth bins, and a colormap for each.
func test_textures() -> void:
	var vol = lib.open(lib.latest())
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
	var vol = lib.open(lib.volumes[0])
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
	var cache = VolumeCacheScript.new(lib.source)
	var paths: Array[String] = []
	for p in lib.volumes:
		if paths.size() < 3 and lib.open(p).is_complete():
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


## Column products (nexrad/src/products.rs) arrive as one extra sweep after the real ones; the
## plan view, readout and mosaic treat it as the only "tilt" of CREF / ET / VIL. Over the
## lowest tilt's ground point CREF is at least that tilt's REF.
func test_products() -> void:
	var vol = lib.open(lib.latest())
	var i: int = vol.sweep_count() - 1
	if not check(vol.is_product(i), "last sweep is the products"):
		return
	for p in RadarVolume.PRODUCTS:
		check_eq(vol.tilts(p), [i] as Array[int], "%s tilts" % p)
		check_eq(vol.tilt_near(p, 3.0), i, "%s at any elevation" % p)
		check(vol.get_texture(i, p) != null, "%s texture" % p)
		check(ColormapsScript.texture_for(p) != null, "%s colormap" % p)
	check(not vol.tilts("REF").has(i), "products are not a REF tilt")
	var low: int = vol.tilts("REF")[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var bad := 0
	var stormy := 0
	for k in 400:
		var az := rng.randf_range(0.0, 360.0)
		var r := rng.randf_range(2.0, 60.0)
		var ref: float = vol.value_at(low, "REF", az, r)
		var cref: float = vol.value_at(i, "CREF", az, r)
		if ref > -900.0 and cref < ref - 1.0:
			bad += 1
		if cref >= 40.0:
			stormy += 1
			var et: float = vol.value_at(i, "ET", az, r)
			check(
				et > 0.0,
				"echo top %.2f over a %.0f dBZ column at %.0f° %.1f km" % [et, cref, az, r]
			)
	check(bad == 0, "CREF below the lowest tilt's REF at %d of 400 points" % bad)
	if fixtures:
		check(stormy > 0, "some points in the fixture storm")


## Rotation tracks: one layer per loop volume; the track over two frames is at least the
## rotation of either frame alone, and covers more ground than one frame.
func test_rotation_tracks() -> void:
	var vols: Array[RadarVolume] = []
	for name in lib.for_site(lib.site_of(lib.volumes[0])):
		vols.append(lib.open(name))
	var t := RotationTracks.build(vols)
	if not check(t != null, "tracks built"):
		return
	check_eq(t.names.size(), vols.size(), "one layer per volume")
	check_eq(t.texture.get_layers(), vols.size(), "texture layers")
	if not fixtures or vols.size() < 2:
		return
	var one := 0
	var both := 0
	for az in range(0, 360, 2):
		for r in range(4, 60):
			var a := RotationTracks.value_at(vols, 1, az, r)
			var b := RotationTracks.value_at(vols, 2, az, r)
			check(b >= a, "track grows with frames at %d° %d km" % [az, r])
			one += int(a > -900.0)
			both += int(b > -900.0)
	check(one > 0 and both > one, "the fixture storm moves: %d then %d points" % [one, both])
