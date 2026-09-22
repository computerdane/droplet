class_name StormCells
extends RefCounted
## Storm cells (nexrad/src/cells.rs writes them into each volume.json) tracked through a loop:
## each frame's cells are matched to the previous frame's, nearest first, against where those
## were heading (their motion so far), within MATCH_KM. A matched cell keeps its id and extends
## its track; its motion is the displacement over the last MOTION_FRAMES positions.

const MATCH_KM := 10.0  # from the predicted position of a cell with a motion estimate
const MATCH_KM_NEW := 15.0  # from the last position of a cell seen once
const MAX_GAP_SEC := 20 * 60  # frames further apart than this are not linked
const MOTION_FRAMES := 4
const FORECAST_MIN: Array[int] = [15, 30, 45]
## Low-level rotation (10⁻³ s⁻¹) drawn as a mesocyclone ring, and as a strong one.
const ROT_MESO := 8.0
const ROT_STRONG := 15.0


## Tracked cells for every frame of `vols` (one site's loop, oldest first): per frame an Array
## of the volume's cells, each a copy with "id", "pos" (Vector2 km east, north), "track"
## (PackedVector2Array of its positions so far, oldest first, ending at "pos") and "motion"
## (Vector2 m/s east, north; Vector2.INF until it has been seen twice).
static func track(vols: Array[RadarVolume]) -> Array:
	var frames := []
	var prev: Array = []
	var prev_t := 0
	var next_id := 1
	for vol in vols:
		var t := RadarLibrary.unix_of(vol.name)
		var cur := []
		var found = vol.meta.get("cells")
		for c in found if found is Array else []:
			var cell: Dictionary = c.duplicate()
			cell["pos"] = Vector2(float(c["x_km"]), float(c["y_km"]))
			cell["id"] = 0
			cur.append(cell)
		var dt := float(t - prev_t)
		if not prev.is_empty() and dt > 0.0 and dt <= MAX_GAP_SEC:
			_link(prev, cur, dt)
		for cell in cur:
			if cell["id"] == 0:
				cell["id"] = next_id
				next_id += 1
				cell["track"] = PackedVector2Array([cell["pos"]])
				cell["times"] = PackedInt64Array([t])
				cell["motion"] = Vector2.INF
			else:
				var times: PackedInt64Array = cell["times"]  # packed arrays are values: copy, append, store
				times.append(t)
				cell["times"] = times
				cell["motion"] = _motion(cell["track"], cell["times"])
		frames.append(cur)
		prev = cur
		prev_t = t
	return frames


## Greedy one-to-one matching of `cur` to `prev`, closest pairs first.
static func _link(prev: Array, cur: Array, dt: float) -> void:
	var pairs := []
	for i in cur.size():
		for j in prev.size():
			var p: Dictionary = prev[j]
			var known: bool = p["motion"] != Vector2.INF
			var guess: Vector2 = p["pos"] + (p["motion"] * dt / 1000.0 if known else Vector2.ZERO)
			var d: float = (cur[i]["pos"] as Vector2).distance_to(guess)
			if d <= (MATCH_KM if known else MATCH_KM_NEW):
				pairs.append([d, i, j])
	pairs.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var used_cur := {}
	var used_prev := {}
	for pr in pairs:
		if used_cur.has(pr[1]) or used_prev.has(pr[2]):
			continue
		used_cur[pr[1]] = true
		used_prev[pr[2]] = true
		var c: Dictionary = cur[pr[1]]
		var p: Dictionary = prev[pr[2]]
		c["id"] = p["id"]
		var tr: PackedVector2Array = (p["track"] as PackedVector2Array).duplicate()
		tr.append(c["pos"])
		c["track"] = tr
		c["times"] = (p["times"] as PackedInt64Array).duplicate()


## m/s east, north from the last MOTION_FRAMES positions.
static func _motion(tr: PackedVector2Array, times: PackedInt64Array) -> Vector2:
	var n := tr.size()
	var k := maxi(0, n - MOTION_FRAMES)
	var dt := float(times[n - 1] - times[k])
	if dt <= 0.0:
		return Vector2.INF
	return (tr[n - 1] - tr[k]) * 1000.0 / dt


## Forecast positions (km) FORECAST_MIN minutes ahead, or none without a motion.
static func forecast(cell: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	var m: Vector2 = cell["motion"]
	if m == Vector2.INF:
		return out
	for minutes in FORECAST_MIN:
		out.append(cell["pos"] + m * minutes * 60.0 / 1000.0)
	return out


## The cell whose centroid is nearest `pos` (km east, north), if within `km`, else {}.
static func nearest(cells: Array, pos: Vector2, km: float) -> Dictionary:
	var best := {}
	for c in cells:
		var d := (c["pos"] as Vector2).distance_to(pos)
		if d <= km and (best.is_empty() or d < (best["pos"] as Vector2).distance_to(pos)):
			best = c
	return best


## Readout lines for a cell.
static func describe(c: Dictionary) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append(
		(
			"Cell %d  %.0f dBZ  VIL %.0f kg/m²  top %.1f km"
			% [c["id"], c["max_dbz"], c["vil"], c["top_km"]]
		)
	)
	var m: Vector2 = c["motion"]
	if m != Vector2.INF:
		var from := fposmod(rad_to_deg(atan2(-m.x, -m.y)), 360.0)
		var kt := m.length() * Colormaps.KT_PER_MS
		lines.append(
			"moving from %03d° at %.0f m/s (%.0f kt)" % [roundi(from) % 360, m.length(), kt]
		)
	if float(c["rot"]) >= ROT_MESO or c["tds"]:
		var tds := "  debris signature (TDS)" if c["tds"] else ""
		lines.append("rotation %.0f × 10⁻³/s%s" % [c["rot"], tds])
	return lines
