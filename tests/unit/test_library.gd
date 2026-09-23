extends "res://tests/test_case.gd"
## RadarLibrary indexing, sequences, tilt selection and storm motion lookup.

const RadarLibraryScript := preload("res://scripts/radar_library.gd")


func test_fixture_set() -> void:
	if not fixtures:
		return
	check_eq(lib.sites(), ["KTST", "KTSU"], "sites")
	check_eq(lib.for_site("KTST").size(), 2, "KTST volumes")
	check_eq(lib.latest("KTST").get_file(), "KTST_20240501_220500", "latest KTST")
	for v in lib.volumes:
		var vol = lib.open(v)
		check(vol.is_complete(), "%s complete" % v.get_file())
		for i in vol.sweep_count():
			check(vol.has_field(i, "VEL") == vol.has_field(i, "DVEL"), "DVEL next to VEL")


## Tilts must be sorted by elevation, unique per angle, and each carry the field.
func test_tilts() -> void:
	for v in lib.volumes:
		var vol = lib.open(v)
		for f in ["REF", "VEL"]:
			var tilts: Array[int] = vol.tilts(f)
			for j in tilts.size():
				check(vol.has_field(tilts[j], f), "%s tilt %d has %s" % [v.get_file(), j, f])
				if j > 0:
					var step: float = vol.elevation(tilts[j]) - vol.elevation(tilts[j - 1])
					check(step >= 0.2, "%s %s tilts %d apart by %.2f" % [v.get_file(), f, j, step])
	if not fixtures:
		return
	# Split cut at 0.5 (surveillance sweep 0, Doppler sweep 1) and a SAILS repeat (sweep 7),
	# all with the same gate count: the latest wins.
	var vol = lib.open(lib.for_site("KTST")[0])
	var elevs := []
	for i in vol.tilts("REF"):
		elevs.append(snappedf(vol.elevation(i), 0.5))
	check_eq(elevs, [0.5, 1.5, 3.0, 5.0, 7.5, 11.0], "REF tilt elevations")
	check_eq(vol.tilts("REF")[0], 7, "REF 0.5 tilt")
	check_eq(vol.tilts("ZDR"), [0, 2] as Array[int], "ZDR tilts")
	check_eq(vol.tilt_near("VEL", 0.9), 7, "VEL tilt near 0.9")
	check_eq(vol.tilt_near("VEL", 1.1), 2, "VEL tilt near 1.1")


func test_sequences() -> void:
	for site in lib.sites():
		var list: Array[String] = lib.for_site(site)
		var i := 0
		while i < list.size():
			var b: Vector2i = RadarLibraryScript.sequence_bounds(list, i)
			if not check(b.x == i and b.y >= i, "sequence_bounds(%d) = %s" % [i, b]):
				return
			i = b.y + 1
	if fixtures:
		var ktst: Array[String] = lib.for_site("KTST")
		check_eq(RadarLibraryScript.sequence_bounds(ktst, 1), Vector2i(0, 1), "KTST loop")


## Every volume with a VAD storm motion must find its own; one without must find the nearest
## in time (same site first).
func test_storm_motion() -> void:
	var with: Array[String] = []
	for v in lib.volumes:
		if lib.winds(v).get("storm_motion") is Dictionary:
			with.append(v)
	if with.is_empty():
		note("none computed (nexrad winds)")
		check(not fixtures, "fixtures carry storm motion")
		return
	for v in lib.volumes:
		var near: Dictionary = lib.storm_motion_near(v, 3600)
		if with.has(v):
			check_eq(near.get("name", ""), v, "own storm motion")
		if not near.is_empty():
			var dt: int = absi(lib.unix_of(near["name"]) - lib.unix_of(v))
			check(dt <= 3600, "%s: storm motion from %d s away" % [v.get_file(), dt])
	if fixtures:
		# KTSU scans two tilts, too shallow for a profile; it borrows KTST's nearest volume.
		var near: Dictionary = lib.storm_motion_near(lib.latest("KTSU"), 3600)
		check_eq(near.get("name", "").get_file(), "KTST_20240501_220000", "KTSU borrows")
		var sm: Dictionary = lib.winds(with[0])["storm_motion"]
		check_eq(sm["method"], "bunkers", "storm motion method")


func test_option_times() -> void:
	check_eq(AppOptions.iso_of_name_time("20130520_200359"), "2013-05-20T20:03:59Z", "time= as ISO")


## Storm cells: the fixture storm is one cell in each KTST volume, linked into one track whose
## motion is the scene's storm motion (10 m/s east, 6 m/s north).
func test_cell_tracking() -> void:
	var vols: Array[RadarVolume] = []
	for name in lib.for_site("KTST" if fixtures else lib.site_of(lib.volumes[0])):
		vols.append(lib.open(name))
	var frames := StormCells.track(vols)
	check_eq(frames.size(), vols.size(), "one frame per volume")
	if not fixtures:
		return
	if not check(
		frames.size() == 2 and frames[0].size() == 1 and frames[1].size() == 1, "one cell each"
	):
		return
	var a: Dictionary = frames[0][0]
	var b: Dictionary = frames[1][0]
	check_eq(b["id"], a["id"], "same track")
	check_eq((b["track"] as PackedVector2Array).size(), 2, "track of two positions")
	check_eq(a["motion"], Vector2.INF, "no motion from one position")
	var m: Vector2 = b["motion"]
	check(m.distance_to(Vector2(10, 6)) < 2.5, "motion %s ~ (10, 6) m/s" % m)
	check(b["rot"] >= StormCells.ROT_MESO and b["tds"], "rotating, with a debris signature")
	var ahead := StormCells.forecast(b)
	check_eq(ahead.size(), StormCells.FORECAST_MIN.size(), "forecast points")
	check(ahead[0].distance_to(b["pos"] + m * 0.9) < 0.01, "15 min ahead")
	check_eq(StormCells.nearest(frames[1], b["pos"] + Vector2(3, 0), 6.0), b, "nearest cell")
	check_eq(StormCells.nearest(frames[1], b["pos"] + Vector2(30, 0), 6.0), {}, "none nearby")


## Mosaic cells: the neighbour KTSU sees the fixture storm too; its cell, turned and moved into
## KTST's frame, lands on KTST's cell. Nearer KTST, the storm is shown once, as KTST's.
func test_mosaic_cells() -> void:
	if not fixtures:
		return
	var cache: VolumeCache = VolumeCache.new(lib.source)
	var own: RadarVolume = lib.open(lib.latest("KTST"))
	var neighbors := Mosaic.neighbors(lib, cache, own, "REF", 0.5)
	if not check_eq(neighbors.size(), 1, "KTSU is a neighbour"):
		return
	var n: Dictionary = neighbors[0]
	var theirs: Array = (n["volume"] as RadarVolume).meta.get("cells", [])
	var frames := StormCells.track([own] as Array[RadarVolume])
	if not check(not theirs.is_empty() and frames[0].size() == 1, "each radar sees the storm"):
		return
	var cell := {"pos": Vector2(theirs[0]["x_km"], theirs[0]["y_km"])}
	cell["track"] = PackedVector2Array([cell["pos"]])
	cell["motion"] = Vector2(10, 6)
	var moved := StormCells.from_neighbor(cell, n["offset_km"], n["rotation"], "KTSU")
	var mine: Vector2 = frames[0][0]["pos"]
	check(
		moved["pos"].distance_to(mine) < 3.0, "KTSU's cell %s at KTST's %s" % [moved["pos"], mine]
	)
	check(
		(moved["motion"] as Vector2).distance_to(Vector2(10, 6)) < 0.5,
		"motion barely turned over 60 km"
	)
	check_eq(moved["site"], "KTSU", "site named")
	var radars := PackedVector2Array([Vector2.ZERO, n["offset_km"]])
	check_eq(StormCells.nearest_radar(mine, radars), 0, "the storm is nearer KTST")
	var ov := Overlays.new()
	ov.library = lib
	var loop: Array[RadarVolume] = [own]
	var shown: Array = ov._mosaic_cells(frames[0], loop, neighbors)
	check_eq(shown.size(), 1, "one cell in the mosaic")
	check(not shown[0].has("site"), "KTST's own")
	ov.free()
