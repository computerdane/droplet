class_name Overlays
extends Node
## Context over the 2D view for the volume on screen: NWS warnings in effect (Warnings) and the
## storm cells of the selected site tracked through the loop (StormCells), with their lines in
## the info text and the hover readout. main.gd calls update() on every refresh.

## A warnings download landed; main refreshes.
signal changed

## Cells within this of the mouse are described in the readout.
const READOUT_CELL_KM := 6.0

var warnings := Warnings.new()
var cells_on := true
var active_warnings: Array = []  # Warnings.active_at() the volume's time
var cells: Array = []  # this frame's tracked cells (StormCells.track())
var _cell_frames: Array = []
var _cell_names: Array[String] = []  # the loop _cell_frames was tracked for


func _ready() -> void:
	add_child(warnings)
	warnings.changed.connect(changed.emit)


## `loop` is the selected site's loop (oldest first), `index` the frame on screen within it.
func update(view: PpiView, volume: RadarVolume, loop: Array[RadarVolume], index: int) -> void:
	var t := RadarLibrary.unix_of(volume.name) if volume != null else 0
	active_warnings = warnings.active_at(t)
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
	if volume == null:
		view.set_warnings([])
		view.set_cells([])
		return
	var lat := float(volume.meta["latitude"])
	var lon := float(volume.meta["longitude"])
	view.set_warnings(Warnings.project(active_warnings, lat, lon))
	view.set_cells(cells)


func info_lines() -> PackedStringArray:
	var lines := PackedStringArray()
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
	return lines
