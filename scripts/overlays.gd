class_name Overlays
extends Node
## Context over the 2D and 3D views for the volume on screen: NWS warnings in effect
## (Warnings), the SPC day 1 outlook (Outlooks, 2D only) and the storm cells of the selected
## site tracked through the loop (StormCells), with their lines in the info text and the hover
## readout. Owns their toggles: A / C / O and the HUD's Warnings / Cells / SPC buttons, and the
## warnings= cells= outlook= options. main.gd calls update() on every refresh.

## A download landed or a toggle changed; main refreshes the overlays.
signal changed

## Cells within this of the mouse are described in the readout.
const READOUT_CELL_KM := 6.0

var warnings := Warnings.new()
var outlooks := Outlooks.new()
var cells_on := true
var active_warnings: Array = []  # Warnings.active_at() the volume's time
var active_outlook: Array = []  # Outlooks.active_at() the volume's time
var cells: Array = []  # this frame's tracked cells (StormCells.track())
var _cell_frames: Array = []
var _cell_names: Array[String] = []  # the loop _cell_frames was tracked for
var _hud: Hud


func _ready() -> void:
	add_child(warnings)
	add_child(outlooks)
	warnings.changed.connect(changed.emit)
	outlooks.changed.connect(changed.emit)


func setup(hud: Hud, opts: Dictionary) -> void:
	_hud = hud
	warnings.enabled = opts.get("warnings", "1") == "1"
	cells_on = opts.get("cells", "1") == "1"
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


## `loop` is the selected site's loop (oldest first), `index` the frame on screen within it.
func update(
	view: PpiView, view_3d: VolumeView3D, volume: RadarVolume, loop: Array[RadarVolume], index: int
) -> void:
	var t := RadarLibrary.unix_of(volume.name) if volume != null else 0
	active_warnings = warnings.active_at(t)
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
	var polys := []
	var outlook_polys := []
	if volume != null:
		var lat := float(volume.meta["latitude"])
		var lon := float(volume.meta["longitude"])
		polys = Warnings.project(active_warnings, lat, lon)
		outlook_polys = Warnings.project(active_outlook, lat, lon)
	view.set_warnings(polys, outlook_polys)
	view.set_cells(cells)
	view_3d.overlay.set_overlays(polys, cells)


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
