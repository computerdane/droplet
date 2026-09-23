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


## Complete scans can be replaced after temporal finalization. Old jobs must not block new
## reads, upload into the replacement, or erase its pending reservations when they retire.
func test_complete_replacement_with_pending_reads() -> void:
	var name: String = lib.latest()
	var text: String = lib.source.read_meta(name)
	var files := {}
	for sw in (JSON.parse_string(text) as Dictionary)["sweeps"]:
		for field in sw["fields"].values():
			files[field["file"]] = lib.source.read_file(name, field["file"])
	var source := MemorySource.new()
	source.add_volume(name, text, files)
	var cache := VolumeCacheScript.new(source)
	var original := cache.get_volume(name)
	cache.prefetch(name, "REF", 0.5, VolumeCacheScript.Need.ALL_TILTS)
	var old_job = cache._jobs[0]
	source.add_volume(name, text, files)
	var replacement := cache.get_volume(name, true)
	check(replacement != original, "refresh replaces stale complete scans")
	var expected := cache.prefetch(name, "REF", 0.5, VolumeCacheScript.Need.ALL_TILTS)
	check_eq(cache.pending_jobs(), 2, "replacement queues while old read is still pending")
	# Retire just the older generation, then ask to prefetch again before the new job uploads.
	cache._retire(old_job)
	cache.prefetch(name, "REF", 0.5, VolumeCacheScript.Need.ALL_TILTS)
	check_eq(cache.pending_jobs(), 1, "old retirement preserves replacement reservations")
	replacement = cache.get_volume(name)
	check_eq(replacement.texture_bytes, expected, "replacement receives its own loaded textures")
	check_eq(original.texture_bytes, 0, "obsolete read did not upload")
	# Public invalidation is also safe with an outstanding array read and a pinned name.
	cache.pin([name])
	cache.prefetch(name, "VEL", 0.5, VolumeCacheScript.Need.TILT_ARRAY)
	cache.invalidate(name)
	var final_volume := cache.get_volume(name)
	check(final_volume != replacement, "explicit invalidation replaces pinned complete scan")
	cache.prefetch(name, "VEL", 0.5, VolumeCacheScript.Need.TILT_ARRAY)
	check_eq(cache.pending_jobs(), 2, "replacement array queues beside obsolete array")
	_drain(cache, Time.get_ticks_msec() + 20000)
	check_eq(cache.pending_jobs(), 0, "all generations finish")
	check(final_volume.tilt_arrays.has("VEL"), "replacement array uploaded")
	check(not replacement.tilt_arrays.has("VEL"), "obsolete array discarded")


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


## HCA holds whole class codes; the categorical colormap paints each class its own colour at
## its code (no blending between neighbours), and the readout names the class.
func test_hca() -> void:
	var tex: GradientTexture1D = ColormapsScript.texture_for("HCA")
	var img := tex.get_image()
	var rng := ColormapsScript.range_of("HCA")
	var n: int = ColormapsScript.HCA_CLASSES.size()
	for k in n:
		var t: float = (k + 1 - rng[0]) / (rng[1] - rng[0])
		var got := img.get_pixel(clampi(int(t * img.get_width()), 0, img.get_width() - 1), 0)
		var want := Color(ColormapsScript.HCA_CLASSES[k][2])
		check(got.is_equal_approx(want), "class %d colour %s, want %s" % [k + 1, got, want])
	check_eq(ColormapsScript.format_value("HCA", 8.0), "light / moderate rain (RA)", "readout")
	if not fixtures:
		return
	var vol = lib.open(lib.latest("KTST"))
	var tilts: Array = vol.tilts("HCA")
	check(not tilts.is_empty(), "fixture has HCA tilts")
	check(vol.meta.get("melting_layer") is Dictionary, "melting layer in volume.json")
	var seen := {}
	for i in tilts:
		var img2: Image = vol.read_image(i, "HCA")
		for y in range(0, img2.get_height(), 7):
			for x in img2.get_width():
				var v := img2.get_pixel(x, y).r
				if v > -900.0:
					check(v == roundf(v) and v >= 1.0 and v <= n, "class code %s" % v)
					seen[int(v)] = true
	check(seen.has(8) or seen.has(9), "rain in the fixture storm: %s" % [seen.keys()])


## Mosaic rotation tracks: the neighbour KTSU gets tracks of its own volumes over the loop's span,
## reaching the frame it shows.
func test_neighbor_tracks() -> void:
	if not fixtures:
		return
	var loop: Array[RadarVolume] = []
	for name in lib.for_site("KTST"):
		loop.append(lib.open(name))
	var cache: VolumeCache = VolumeCacheScript.new(lib.source)
	var neighbors := Mosaic.neighbors(lib, cache, loop[-1], "ROT", 0.0)
	if not check_eq(neighbors.size(), 1, "KTSU is a neighbour"):
		return
	var loops := RotationTracks.Loops.new()
	loops.add_to_neighbors(neighbors, lib, loop)
	var n: Dictionary = neighbors[0]
	check(n["tracks"] != null, "KTSU tracks built")
	check_eq((n["tracks_vols"] as Array).size(), 1, "KTSU's one volume")
	check_eq(n["n_tracks"], 1, "up to the frame shown")
	var own := loops.of(loop)
	check(own != null and loops.of(loop) == own, "own tracks kept while the loop is unchanged")
