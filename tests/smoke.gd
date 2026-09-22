extends SceneTree
## Headless smoke test: godot --headless --path . --script res://tests/smoke.gd
## Loads the newest decoded volume and builds one texture per field of sweep 0.

const RadarLibraryScript := preload("res://scripts/radar_library.gd")
const RadarVolumeScript := preload("res://scripts/radar_volume.gd")
const ColormapsScript := preload("res://scripts/colormaps.gd")
const BasemapScript := preload("res://scripts/basemap.gd")
const VolumeCacheScript := preload("res://scripts/volume_cache.gd")
const SectionViewScript := preload("res://scripts/section_view.gd")


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
	failed = not _check_tilts(vol) or failed
	failed = not _check_sequences(lib) or failed
	failed = not _check_basemap(vol) or failed
	failed = not _check_preload(lib) or failed
	failed = not _check_beam_model() or failed
	failed = not _check_storm_motion(lib) or failed
	quit(1 if failed else 0)


## Tilts must be sorted by elevation, unique per angle, and each carry the field.
func _check_tilts(vol) -> bool:
	var ok := true
	for f in ["REF", "VEL"]:
		var tilts: Array[int] = vol.tilts(f)
		var elevs := PackedStringArray()
		for j in tilts.size():
			var i := tilts[j]
			elevs.append("%.1f" % vol.elevation(i))
			if not vol.has_field(i, f):
				ok = false
			if j > 0 and vol.elevation(i) - vol.elevation(tilts[j - 1]) < 0.2:
				ok = false
		print("  %s tilts: %s" % [f, " ".join(elevs)])
	if not ok:
		push_error("tilt selection broken")
	return ok


func _check_sequences(lib) -> bool:
	for site in lib.sites():
		var list: Array[String] = lib.for_site(site)
		var seqs := PackedStringArray()
		var i := 0
		while i < list.size():
			var b: Vector2i = RadarLibraryScript.sequence_bounds(list, i)
			if b.x != i or b.y < i:
				push_error("sequence_bounds(%d) = %s" % [i, b])
				return false
			seqs.append(str(b.y - b.x + 1))
			i = b.y + 1
		print("  %s sequences (volumes each): %s" % [site, " ".join(seqs)])
	return true


## Projection sanity (1° of latitude due north ≈ 111.19 km) and basemap loading if built.
func _check_basemap(vol) -> bool:
	var lat: float = vol.meta["latitude"]
	var lon: float = vol.meta["longitude"]
	var p: Vector2 = BasemapScript.project(lat + 1.0, lon, lat, lon)
	if absf(p.x) > 1e-6 or absf(p.y - 111.195) > 0.01:
		push_error("projection: 1 deg north -> %s" % p)
		return false
	var bm = BasemapScript.get_shared()
	if bm == null:
		print("  basemap: not built (python -m nexrad basemap)")
		return true
	var near: Array = bm.cities_near(lat, lon, 100.0)
	var names := PackedStringArray()
	for c in near.slice(0, 5):
		names.append("%s %.0f km" % [c[0], (c[1] as Vector2).length()])
	print("  basemap layers: %s  cities <100 km: %s" % [bm.meshes.keys(), ", ".join(names)])
	return not bm.meshes.is_empty()


## Background loading: preload the REF tilts of a few complete volumes, drain the jobs with
## poll() and check every texture arrived; get_volume() must finish a pending job itself.
func _check_preload(lib) -> bool:
	var cache = VolumeCacheScript.new()
	var paths: Array[String] = []
	for p in lib.volumes:
		if paths.size() < 3 and RadarVolumeScript.load_from_dir(p).is_complete():
			paths.append(p)
	var t0 := Time.get_ticks_msec()
	var expected := 0
	for p in paths:
		expected += cache.prefetch(p, "REF", 0.5, VolumeCacheScript.Need.ALL_TILTS)
	var waited = cache.get_volume(paths[0])
	var deadline := t0 + 20000
	while cache.pending_jobs() > 0 and Time.get_ticks_msec() < deadline:
		cache.poll()
		OS.delay_msec(2)
	var ok: bool = cache.pending_jobs() == 0 and cache.used_bytes() == expected
	for p in paths:
		var v = cache.get_volume(p)
		for i in v.tilts("REF"):
			ok = ok and v.has_texture(i, "REF")
	ok = ok and waited.texture_bytes > 0
	# Volume rendering: the whole field as one Texture2DArray, built on a worker too.
	cache.prefetch(paths[1], "VEL", 0.5, VolumeCacheScript.Need.TILT_ARRAY)
	while cache.pending_jobs() > 0 and Time.get_ticks_msec() < deadline:
		cache.poll()
		OS.delay_msec(2)
	var va = cache.get_volume(paths[1])
	var ta = va.tilt_arrays.get("VEL")
	ok = ok and ta != null and ta.texture.get_layers() == va.tilts("VEL").size()
	if ta != null:
		print("  tilt array: VEL %d layers of %d gates" % [ta.texture.get_layers(), ta.width])
	print(
		(
			"  preload: %d volumes, %d MB in %d ms"
			% [paths.size(), cache.used_bytes() >> 20, Time.get_ticks_msec() - t0]
		)
	)
	if not ok:
		push_error("preload: %d of %d bytes loaded" % [cache.used_bytes(), expected])
	return ok


## The cross-section's beam height at a ground range must match cone.gdshader's forward
## model (slant range -> height, ground range), replicated here.
## Every volume with a VAD storm motion must find its own; a volume without one must find
## the nearest one in time (same site first). Skipped when nothing has been computed.
func _check_storm_motion(lib) -> bool:
	var with: Array[String] = []
	for v in lib.volumes:
		if lib.winds(v).get("storm_motion") is Dictionary:
			with.append(v)
	if with.is_empty():
		print("  storm motion: none computed (python -m nexrad winds)")
		return true
	var ok := true
	for v in lib.volumes:
		var near: Dictionary = lib.storm_motion_near(v, 3600)
		if with.has(v) and near.get("path", "") != v:
			ok = false
		if not near.is_empty() and absi(lib.unix_of(near["path"]) - lib.unix_of(v)) > 3600:
			ok = false
	var sm: Dictionary = lib.winds(with[0])["storm_motion"]
	print(
		(
			"  storm motion: %d/%d volumes, %s right mover %s, 0-1 km SRH %d"
			% [with.size(), lib.volumes.size(), with[0].get_file(), sm["right"], sm["srh_0_1km"]]
		)
	)
	if not ok:
		push_error("storm_motion_near broken")
	return ok


func _check_beam_model() -> bool:
	var ke_a := 8494.67
	var worst := 0.0
	for elev in [0.5, 3.0, 19.5]:
		for r in [10.0, 100.0, 300.0]:
			var th := deg_to_rad(elev)
			var num: float = r * r + 2.0 * r * ke_a * sin(th)
			var h: float = num / (sqrt(num + ke_a * ke_a) + ke_a)
			var s: float = ke_a * asin(r * cos(th) / (ke_a + h))
			worst = maxf(worst, absf(SectionViewScript.beam_height(elev, s) - h))
	print("  section beam model: max height error %.4f km" % worst)
	if worst > 0.01:
		push_error("section beam height disagrees with cone.gdshader")
	return worst <= 0.01
