class_name Overlays
extends Node
## Context over the 2D and 3D views for the volume on screen: NWS warnings in effect
## (Warnings), the SPC day 1 outlook (Outlooks, 2D only) and the storm cells tracked through the
## loop (StormCells; in a mosaic each radar's cells where it is the nearest radar, tracked through
## that site's own volumes), with their lines in the info text and the hover
## readout. Owns their toggles: A / C / O and the HUD's Warnings / Cells / SPC buttons, and the
## warnings= cells= outlook= options. main.gd calls update() on every refresh.

## A download landed or a toggle changed; main refreshes the overlays.
signal changed

## Cells within this of the mouse are described in the readout.
const READOUT_CELL_KM := 6.0
## Cells of two radars closer than this are one storm seen twice (mosaic).
const MOSAIC_TWIN_KM := 6.0

var warnings := Warnings.new()
var outlooks := Outlooks.new()
var cells_on := false
var active_warnings: Array = []  # Warnings.active_at() the volume's time
var active_outlook: Array = []  # Outlooks.active_at() the volume's time
var cells: Array = []  # this frame's tracked cells (StormCells.track())
var library: RadarLibrary  # set by main: the mosaic neighbours' loops
var _cell_frames: Array = []
var _cell_names: Array[String] = []  # the loop _cell_frames was tracked for
var _neighbor_cells := {}  # site -> {"names": Array[String], "frames": StormCells.track()}
var _hud: Hud


func _ready() -> void:
	add_child(warnings)
	add_child(outlooks)
	warnings.changed.connect(changed.emit)
	outlooks.changed.connect(changed.emit)


func setup(hud: Hud, opts: Dictionary) -> void:
	_hud = hud
	warnings.enabled = opts.get("warnings", "1") == "1"
	cells_on = opts.get("cells", "0") == "1"
	outlooks.enabled = opts.get("outlook", "0") == "1"
	hud.warnings_toggled.connect(toggle.bind("warnings"))
	hud.cells_toggled.connect(toggle.bind("cells"))
	hud.outlook_toggled.connect(toggle.bind("outlook"))
	_sync_hud()


func toggle(what: String) -> void:
	match what:
		"warnings":
			warnings.enabled = not warnings.enabled
		"cells":
			cells_on = not cells_on
		"outlook":
			outlooks.enabled = not outlooks.enabled
	_sync_hud()
	changed.emit()


func _sync_hud() -> void:
	if _hud != null:
		_hud.set_overlays_on(warnings.enabled, cells_on, outlooks.enabled)


func _unhandled_key_input(event: InputEvent) -> void:
	var e := event as InputEventKey
	if not e.pressed or e.echo:
		return
	var keys := {KEY_A: "warnings", KEY_C: "cells", KEY_O: "outlook"}
	if keys.has(e.keycode):
		toggle(keys[e.keycode])
		get_viewport().set_input_as_handled()


## `loop` is the selected site's loop (oldest first), `index` the frame on screen within it,
## `neighbors` the mosaic neighbours on screen (Mosaic.neighbors(), may be empty).
## In overview mode there is no radar volume: use the current UTC time and the national
## composite's projection center for the SPC outlook.
func update(
	view: PpiView,
	view_3d: VolumeView3D,
	volume: RadarVolume,
	loop: Array[RadarVolume],
	index: int,
	neighbors: Array = [],
	overview: bool = false
) -> void:
	var context := context_for(volume, overview, int(Time.get_unix_time_from_system()))
	var t: int = context.get("time", 0)
	active_warnings = [] if overview else warnings.active_at(t)
	active_outlook = outlooks.active_at(t)
	cells = []
	if cells_on and volume != null:
		var names: Array[String] = []
		for v in loop:
			names.append(v.name)
		if names != _cell_names:
			_cell_names = names
			_cell_frames = StormCells.track(loop)
		if index >= 0 and index < _cell_frames.size():
			cells = _cell_frames[index]
		if not neighbors.is_empty():
			cells = _mosaic_cells(cells, loop, neighbors)
	var polys := []
	var outlook_polys := []
	if not context.is_empty():
		var center: Vector2 = context["center"]
		polys = Warnings.project(active_warnings, center.x, center.y)
		outlook_polys = Warnings.project(active_outlook, center.x, center.y)
	view.set_warnings(polys, outlook_polys)
	view.set_cells(cells)
	view_3d.overlay.set_overlays(polys, cells)


## Context for either a historical site frame or the live national map.
static func context_for(volume: RadarVolume, overview: bool, now: int) -> Dictionary:
	if overview:
		return {"time": now, "center": NationalComposite.CENTER}
	if volume != null:
		return {
			"time": RadarLibrary.unix_of(volume.name),
			"center": Vector2(float(volume.meta["latitude"]), float(volume.meta["longitude"]))
		}
	return {}


## `own` (the selected radar's cells) and every neighbour's cells in the selected radar's frame,
## each kept only where its radar is the nearest one (as the mosaic draws the data).
func _mosaic_cells(own: Array, loop: Array[RadarVolume], neighbors: Array) -> Array:
	var radars := PackedVector2Array([Vector2.ZERO])
	for n in neighbors:
		radars.append(n["offset_km"])
	var out := own.filter(
		func(c: Dictionary) -> bool: return StormCells.nearest_radar(c["pos"], radars) == 0
	)
	if library == null or loop.is_empty():
		return out
	var t0 := RadarLibrary.unix_of(loop[0].name) - Mosaic.MAX_SKEW_SEC
	var t1 := RadarLibrary.unix_of(loop[-1].name) + Mosaic.MAX_SKEW_SEC
	for k in neighbors.size():
		var n: Dictionary = neighbors[k]
		var shown: RadarVolume = n["volume"]
		var site: String = n["site"]
		var names: Array[String] = []
		for name in library.for_site(site):
			var t := RadarLibrary.unix_of(name)
			if t >= t0 and t <= t1:
				names.append(name)
		var memo: Dictionary = _neighbor_cells.get(site, {})
		if memo.get("names", []) != names:
			var vols: Array[RadarVolume] = []
			for name in names:
				var v := RadarVolume.open(library.source, name)
				if v != null:
					vols.append(v)
			memo = {"names": names, "frames": StormCells.track(vols)}
			_neighbor_cells[site] = memo
		var i: int = (memo["names"] as Array).find(shown.name)
		if i < 0 or i >= (memo["frames"] as Array).size():
			continue
		for c: Dictionary in memo["frames"][i]:
			var moved := StormCells.from_neighbor(c, n["offset_km"], n["rotation"], site)
			if StormCells.nearest_radar(moved["pos"], radars) == k + 1:
				# One storm by the boundary between two radars can show up in both: keep the
				# centroid from the radar nearer to it.
				var twin := StormCells.nearest(out, moved["pos"], MOSAIC_TWIN_KM)
				if twin.is_empty():
					out.append(moved)
				elif _radar_km(moved, radars, k + 1) < _radar_km(twin, radars, -1):
					out[out.find(twin)] = moved
	return out


## Distance (km) from a cell to the radar that saw it: index `k` of `radars`, or (k < 0) the
## one it is nearest to.
static func _radar_km(cell: Dictionary, radars: PackedVector2Array, k: int) -> float:
	var pos: Vector2 = cell["pos"]
	return pos.distance_to(radars[k if k >= 0 else StormCells.nearest_radar(pos, radars)])


func info_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	if not active_outlook.is_empty():
		lines.append(Outlooks.summary(active_outlook))
	if not active_warnings.is_empty():
		lines.append("warnings: " + Warnings.summary(active_warnings))
	if cells_on and not cells.is_empty():
		var meso := 0
		var tds := 0
		for c in cells:
			meso += int(float(c["rot"]) >= StormCells.ROT_MESO)
			tds += int(c["tds"])
		var what := "cells: %d" % cells.size()
		if meso > 0:
			what += ", %d rotating" % meso
		if tds > 0:
			what += ", %d with a debris signature" % tds
		lines.append(what)
	return lines


## Readout lines at `lonlat` (Vector2(lon, lat)), `pos` km east, north of the selected radar.
func readout_lines(lonlat: Vector2, pos: Vector2) -> PackedStringArray:
	var lines := PackedStringArray()
	var c := StormCells.nearest(cells, pos, READOUT_CELL_KM)
	if not c.is_empty():
		lines.append_array(StormCells.describe(c))
	for w in Warnings.containing(active_warnings, lonlat):
		lines.append(Warnings.describe(w))
	var area := Outlooks.at_point(active_outlook, lonlat)
	if not area.is_empty():
		lines.append("SPC day 1: " + area["name"].to_lower())
	return lines


## National map hover: keep the clickable station hint above any SPC category.
func overview_readout(world: Vector2, station: String) -> String:
	var lines := PackedStringArray()
	if not station.is_empty():
		lines.append("%s\nClick for recent scans" % station)
	var ll := Basemap.unproject(
		Vector2(world.x, -world.y), NationalComposite.CENTER.x, NationalComposite.CENTER.y
	)
	lines.append_array(readout_lines(Vector2(ll.y, ll.x), Vector2.ZERO))
	return "\n".join(lines)
