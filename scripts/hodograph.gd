class_name Hodograph
extends Control
## Hodograph of a VAD wind profile (nexrad/vad.py): the tip of the wind vector with
## height, coloured by layer (0-1, 1-3, 3-6, 6+ km), with the Bunkers right/left movers,
## the 0-6 km mean wind and the storm motion in use for storm-relative velocity.
## +x east, +y north (up), rings every RING_STEP m/s.

const RING_STEP := 10.0
const MARGIN := 10.0
const TITLE_H := 20.0
const FOOTER_H := 34.0
const FONT_SIZE := 11
const BG := Color(0.03, 0.03, 0.06, 0.85)
const RING := Color(1, 1, 1, 0.14)
const TEXT := Color(1, 1, 1, 0.8)
const LAYERS := [
	[1000.0, Color(0.95, 0.3, 0.3)],
	[3000.0, Color(0.3, 0.85, 0.35)],
	[6000.0, Color(0.95, 0.85, 0.3)],
	[INF, Color(0.4, 0.65, 1.0)],
]

var _heights := PackedFloat32Array()
var _winds := PackedVector2Array()  # m/s east, north
var _motion: Dictionary = {}  # storm_motion from volume.json, or {}
var _in_use := Vector2.INF  # storm motion subtracted, m/s east, north; INF = none
var _title := ""
var _note := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## `profile` / `motion` as stored in volume.json (either may be null); `in_use` is the
## storm vector being subtracted (Vector2.INF when storm-relative display is off).
func show_winds(profile, motion, in_use: Vector2, title: String, note: String) -> void:
	_heights.clear()
	_winds.clear()
	if profile is Dictionary:
		var h: Array = profile.get("height_m", [])
		var u: Array = profile.get("u_ms", [])
		var v: Array = profile.get("v_ms", [])
		for i in mini(h.size(), mini(u.size(), v.size())):
			_heights.append(float(h[i]))
			_winds.append(Vector2(float(u[i]), float(v[i])))
	_motion = motion if motion is Dictionary else {}
	_in_use = in_use
	_title = title
	_note = note
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var font := get_theme_default_font()
	draw_string(font, Vector2(MARGIN, 15), _title, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT)
	var plot := Rect2(Vector2(MARGIN, TITLE_H), size - Vector2(2 * MARGIN, TITLE_H + FOOTER_H))
	var centre := plot.get_center()
	var radius := minf(plot.size.x, plot.size.y) * 0.5
	var max_speed := RING_STEP * 2.0
	for w in _winds:
		max_speed = maxf(max_speed, w.length())
	for key in ["right", "left", "mean_0_6km"]:
		if _motion.has(key):
			max_speed = maxf(max_speed, _vec(_motion[key]).length())
	if _in_use != Vector2.INF:
		max_speed = maxf(max_speed, _in_use.length())
	max_speed = ceilf(max_speed / RING_STEP) * RING_STEP
	var scale := radius / max_speed
	var to_px := func(w: Vector2) -> Vector2: return centre + Vector2(w.x, -w.y) * scale

	for k in range(1, int(max_speed / RING_STEP) + 1):
		var r := k * RING_STEP * scale
		draw_arc(centre, r, 0.0, TAU, 64, RING, 1.0, true)
		var label := "%d" % int(k * RING_STEP)
		draw_string(
			font, centre + Vector2(3, -r + 11), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, RING * 3.0
		)
	draw_line(centre - Vector2(radius, 0), centre + Vector2(radius, 0), RING)
	draw_line(centre - Vector2(0, radius), centre + Vector2(0, radius), RING)

	if _winds.is_empty():
		draw_string(
			font,
			centre + Vector2(-radius, 4),
			"no wind profile",
			HORIZONTAL_ALIGNMENT_CENTER,
			2 * radius,
			FONT_SIZE,
			TEXT
		)
	for i in range(1, _winds.size()):
		var col := _layer_colour(0.5 * (_heights[i - 1] + _heights[i]))
		# Gaps in the profile (no VAD level) are drawn thin.
		var gap := _heights[i] - _heights[i - 1] > 600.0
		draw_line(to_px.call(_winds[i - 1]), to_px.call(_winds[i]), col, 1.0 if gap else 2.5, true)
	for km in [1, 3, 6, 9]:
		var i := _index_near(km * 1000.0)
		if i >= 0:
			var p: Vector2 = to_px.call(_winds[i])
			draw_circle(p, 2.5, TEXT)
			draw_string(font, p + Vector2(4, -3), str(km), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, TEXT)

	if _motion.has("right"):
		_marker(font, to_px.call(_vec(_motion["right"])), "RM", Color(1, 0.55, 0.55))
		_marker(font, to_px.call(_vec(_motion["left"])), "LM", Color(0.6, 0.75, 1))
		var m: Vector2 = to_px.call(_vec(_motion["mean_0_6km"]))
		draw_rect(Rect2(m - Vector2(3, 3), Vector2(6, 6)), TEXT, false, 1.0)
	if _in_use != Vector2.INF:
		var p: Vector2 = to_px.call(_in_use)
		draw_line(p - Vector2(6, 6), p + Vector2(6, 6), Color.WHITE, 2.0)
		draw_line(p - Vector2(6, -6), p + Vector2(6, -6), Color.WHITE, 2.0)

	var y := size.y - FOOTER_H + 13
	if _motion.has("srh_0_1km"):
		var srh := (
			"SRH (RM)  0-1 km %d   0-3 km %d m²/s²"
			% [roundi(_motion["srh_0_1km"]), roundi(_motion["srh_0_3km"])]
		)
		draw_string(font, Vector2(MARGIN, y), srh, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT)
	draw_string(
		font, Vector2(MARGIN, y + 15), _note, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT * 0.8
	)


func _marker(font: Font, p: Vector2, text: String, col: Color) -> void:
	draw_circle(p, 4.0, col)
	draw_string(font, p + Vector2(6, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)


func _index_near(h: float) -> int:
	var best := -1
	for i in _heights.size():
		if (
			absf(_heights[i] - h) <= 250.0
			and (best < 0 or absf(_heights[i] - h) < absf(_heights[best] - h))
		):
			best = i
	return best


static func _layer_colour(h: float) -> Color:
	for layer in LAYERS:
		if h < layer[0]:
			return layer[1]
	return LAYERS[-1][1]


static func _vec(a) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


## Meteorological "from" direction (degrees) and speed (m/s) of a vector (+x east, +y north).
static func from_dir_speed(w: Vector2) -> Vector2:
	return Vector2(fposmod(rad_to_deg(atan2(-w.x, -w.y)), 360.0), w.length())
