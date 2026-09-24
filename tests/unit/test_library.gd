extends "res://tests/test_case.gd"
## RadarLibrary indexing, sequences, tilt selection and storm motion lookup.

const RadarLibraryScript := preload("res://scripts/radar_library.gd")
const VolumeUpdatePolicyScript := preload("res://scripts/volume_update_policy.gd")


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


func test_for_site_window() -> void:
	var site: String = lib.sites()[0]
	var all: Array[String] = lib.for_site(site)
	check_eq(lib.for_site(site, null), all, "no window: every scan")
	var newest := RadarLibraryScript.unix_of(all[-1])
	var only: Array[String] = [all[-1]]
	check_eq(lib.for_site(site, TimeWindow.fixed(newest, newest)), only, "inclusive window")
	check_eq(lib.for_site(site, TimeWindow.fixed(newest + 1, newest + 60)), [], "after the newest")
	check_eq(lib.for_site(site, TimeWindow.live_window(60, newest + 3601)), [], "live, 1 s past")
	var window := TimeWindow.fixed(RadarLibraryScript.unix_of(all[0]), newest)
	check_eq(lib.for_site(site, window), all, "window spanning all")
	check_eq(lib.for_site(site, window), window.filter(all), "same as TimeWindow.filter")
	check_eq(lib.latest_site(TimeWindow.fixed(0, 1)), lib.site_of(lib.latest()), "none: newest")
	if fixtures:
		check_eq(lib.latest_site(window), "KTST", "the site with the newest scan inside")
		var ktsu := RadarLibraryScript.unix_of(lib.latest("KTSU"))
		check_eq(lib.latest_site(TimeWindow.fixed(ktsu, ktsu)), "KTSU", "only KTSU inside")


func test_volume_quality() -> void:
	var vol: RadarVolume = lib.open(lib.volumes[0])
	check_eq(VolumeUpdatePolicyScript.quality(vol), "", "complete scan has no quality warning")
	vol.meta["provisional"] = true
	check_eq(
		VolumeUpdatePolicyScript.quality(vol), "  (provisional)", "unfinalized scan is labeled"
	)
	vol.meta["complete"] = false
	check_eq(
		VolumeUpdatePolicyScript.quality(vol), "  (partial)", "growing scan is labeled partial"
	)


func test_live_target_and_replaced_loop_frame() -> void:
	if not fixtures:
		return
	var names: Array[String] = lib.for_site("KTST")
	var source := MemorySource.new()
	source.add_volume(names[-1], lib.source.read_meta(names[-1]), {})
	var index := RadarLibraryScript.new(source)
	var current: RadarVolume = index.open(names[-1])
	var frames: Array[String] = index.for_site("KTST")
	check_eq(VolumeUpdatePolicyScript.live_target(frames, current, false), "", "newest pinned")
	source.add_volume(names[0], lib.source.read_meta(names[0]), {})
	index.scan()
	frames = index.for_site("KTST")
	check_eq(
		VolumeUpdatePolicyScript.live_target(frames, current, false), "", "older backfill stays"
	)
	check(
		VolumeUpdatePolicyScript.shown_in_loop(names[0], current, index.for_site("KTST"), 1),
		"older loop frame updates"
	)
	source.add_volume(names[-1], lib.source.read_meta(names[-1]), {})
	check_eq(
		VolumeUpdatePolicyScript.live_target(frames, current, false), names[-1], "same name reloads"
	)
	check_eq(
		VolumeUpdatePolicyScript.live_target(frames, current, true), "", "playback stays on frame"
	)
	var window := TimeWindow.fixed(0, RadarLibraryScript.unix_of(names[0]))
	check_eq(
		VolumeUpdatePolicyScript.live_target(index.for_site("KTST", window), null, false),
		names[0],
		"the newest inside the window, not the newest cached"
	)
	check_eq(
		VolumeUpdatePolicyScript.live_target([] as Array[String], current, false),
		"",
		"nothing in the window: stay"
	)


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


func test_cells_overlay_option_and_toggles() -> void:
	var hud := Hud.new()
	hud.warnings_button = Button.new()
	hud.cells_button = Button.new()
	hud.outlook_button = Button.new()
	hud.location_button = Button.new()
	hud.cells_button.toggle_mode = true
	var ov := Overlays.new()
	check(not ov.cells_on, "cells start off before setup")
	ov.setup(hud, {})
	check(not ov.cells_on and not hud.cells_button.button_pressed, "cells default off in HUD")
	hud.cells_toggled.emit()
	check(ov.cells_on and hud.cells_button.button_pressed, "HUD enables cells")
	ov.toggle("cells")
	check(not ov.cells_on and not hud.cells_button.button_pressed, "toggle disables cells")
	ov.warnings.free()
	ov.outlooks.free()
	ov.location.free()
	ov.free()
	var explicit := Overlays.new()
	explicit.setup(hud, {"cells": "1"})
	check(explicit.cells_on and hud.cells_button.button_pressed, "cells=1 enables cells")
	explicit.warnings.free()
	explicit.outlooks.free()
	explicit.location.free()
	explicit.free()
	hud.warnings_button.free()
	hud.cells_button.free()
	hud.outlook_button.free()
	hud.location_button.free()
	hud.free()


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
	var t := RadarLibraryScript.unix_of(own.name)
	check_eq(
		Mosaic.path_near(lib, "KTSU", t, TimeWindow.fixed(t - 3600, t + 3600)),
		lib.for_site("KTSU")[0],
		"a neighbour inside the window"
	)
	check_eq(
		Mosaic.path_near(lib, "KTSU", t, TimeWindow.fixed(t + 3600, t + 7200)),
		"",
		"none inside the window"
	)
	check_eq(
		Mosaic.neighbors(lib, cache, own, "REF", 0.5, TimeWindow.fixed(t, t)).size(),
		0,
		"the window bounds neighbours"
	)
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
