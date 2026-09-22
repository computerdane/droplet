class_name WindProfileView
extends Control
## VAD wind profile over time (a VWP, like the NWS product): one column of wind barbs per
## volume of the loop, height up to the top of the highest profile, coloured by speed.
## Data is each volume's `wind_profile` (nexrad/src/vad.rs, 250 m bins centred 125 m + k*250 m
## above the radar). The current volume's column is highlighted; clicking a column jumps
## to that volume. Barbs point into the wind, feathers on the low-pressure side (northern
## hemisphere), in knots: pennant 50, full feather 10, half 5.

signal frame_picked(path: String)

const MARGIN_LEFT := 34.0
const MARGIN_RIGHT := 10.0
const MARGIN_TOP := 24.0
const MARGIN_BOTTOM := 22.0
const FONT_SIZE := 11
const BIN_M := 250.0
const FIRST_BIN_M := 125.0
const MIN_ROW_PX := 16.0
const MIN_COL_PX := 20.0
const MIN_TOP_KM := 3.0
const MAX_TOP_KM := 16.0
const BG := Color(0.03, 0.03, 0.06, 0.88)
const PLOT_BG := Color(0.07, 0.08, 0.11)
const GRID := Color(1, 1, 1, 0.12)
const TEXT := Color(1, 1, 1, 0.8)
const CURRENT := Color(1, 1, 1, 0.1)
## Barb colour by speed in knots.
const SPEED_STOPS := [
	[0.0, Color(0.55, 0.7, 1.0)],
	[20.0, Color(0.3, 0.9, 0.4)],
	[40.0, Color(0.95, 0.9, 0.3)],
	[60.0, Color(1.0, 0.45, 0.25)],
	[80.0, Color(1.0, 0.35, 0.9)],
]

var _columns: Array = []  # {path, t (unix), heights: PackedFloat32Array, winds: PackedVector2Array}
var _current := -1  # index into _columns
var _title := ""
var _layout := {}  # computed by _plan(): shown columns, row heights, scales


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


## `columns`: [{path, t, profile}] in time order, `profile` as stored in volume.json (or
## null); `current` is the index of the volume on screen.
func show_profiles(columns: Array, current: int, title: String) -> void:
	_columns.clear()
	for c: Dictionary in columns:
		var heights := PackedFloat32Array()
		var winds := PackedVector2Array()
		var profile = c.get("profile")
		if profile is Dictionary:
			var h: Array = profile.get("height_m", [])
			var u: Array = profile.get("u_ms", [])
			var v: Array = profile.get("v_ms", [])
			for i in mini(h.size(), mini(u.size(), v.size())):
				heights.append(float(h[i]))
				winds.append(Vector2(float(u[i]), float(v[i])))
		_columns.append({"path": c["path"], "t": c["t"], "heights": heights, "winds": winds})
	_current = current
	_title = title
	queue_redraw()


func _plot_rect() -> Rect2:
	return Rect2(
		Vector2(MARGIN_LEFT, MARGIN_TOP),
		size - Vector2(MARGIN_LEFT + MARGIN_RIGHT, MARGIN_TOP + MARGIN_BOTTOM)
	)


## Which columns and rows fit: {cols: [index into _columns], rows: [height m], top_m,
## x: {index -> px}, cell (px, the smaller of row and column spacing)}.
func _plan() -> Dictionary:
	var r := _plot_rect()
	var out := {"cols": [], "rows": [], "top_m": MIN_TOP_KM * 1000.0, "x": {}, "cell": 0.0}
	if _columns.is_empty() or r.size.x <= 0 or r.size.y <= 0:
		return out
	var top := MIN_TOP_KM * 1000.0
	for c in _columns:
		var hs: PackedFloat32Array = c["heights"]
		if not hs.is_empty():
			top = maxf(top, hs[-1] + BIN_M)
	top = minf(ceilf(top / 1000.0), MAX_TOP_KM) * 1000.0
	out["top_m"] = top
	# Rows on the profile's bin centres, every `stride` bins so they stay MIN_ROW_PX apart.
	var bin_px := r.size.y * BIN_M / top
	var row_stride := maxi(1, ceili(MIN_ROW_PX / bin_px))
	var h := FIRST_BIN_M
	while h < top:
		out["rows"].append(h)
		h += BIN_M * row_stride
	# Columns placed by time with half a typical spacing of padding at each end; thinned
	# (always keeping the current one) when they would crowd.
	var t0: int = _columns[0]["t"]
	var t1: int = _columns[-1]["t"]
	var n := _columns.size()
	var pad := 0.5 * float(t1 - t0) / maxf(n - 1, 1) if n > 1 else 1.0
	var span := float(t1 - t0) + 2.0 * pad
	var col_px := r.size.x * (span - 2.0 * pad) / span / maxf(n - 1, 1) if n > 1 else r.size.x
	var col_stride := maxi(1, ceili(MIN_COL_PX / maxf(col_px, 0.01)))
	var anchor := clampi(_current, 0, n - 1)
	for i in n:
		if (i - anchor) % col_stride == 0:
			out["cols"].append(i)
			out["x"][i] = r.position.x + (float(_columns[i]["t"] - t0) + pad) / span * r.size.x
	out["cell"] = minf(bin_px * row_stride, col_px * col_stride)
	return out


func _y_of(h_m: float, top_m: float) -> float:
	var r := _plot_rect()
	return r.end.y - h_m / top_m * r.size.y


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)
	var font := get_theme_default_font()
	draw_string(font, Vector2(8, 16), _title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT)
	var r := _plot_rect()
	if r.size.x <= 0 or r.size.y <= 0:
		return
	draw_rect(r, PLOT_BG)
	_layout = _plan()
	var top_m: float = _layout["top_m"]
	var km_step := 1 if top_m <= 6000.0 else (2 if top_m <= 12000.0 else 4)
	for km in range(0, int(top_m / 1000.0) + 1, km_step):
		var y := _y_of(km * 1000.0, top_m)
		draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), GRID)
		draw_string(
			font,
			Vector2(4, y + 4),
			str(km),
			HORIZONTAL_ALIGNMENT_RIGHT,
			MARGIN_LEFT - 8,
			FONT_SIZE,
			TEXT
		)
	if _columns.is_empty():
		draw_string(
			font,
			r.position + Vector2(0, r.size.y / 2),
			"no volumes",
			HORIZONTAL_ALIGNMENT_CENTER,
			r.size.x,
			FONT_SIZE,
			TEXT
		)
		return
	var cols: Array = _layout["cols"]
	var cell: float = _layout["cell"]
	var staff := clampf(cell * 0.9, 8.0, 22.0)
	# Time labels: the current column's, and as many others as fit around it.
	var label_w := 44.0
	var current_x: float = _layout["x"].get(_current, -INF)
	var last_label_x := -INF
	for i: int in cols:
		var x: float = _layout["x"][i]
		if i == _current:
			var w := maxf(cell, 6.0)
			draw_rect(Rect2(x - w / 2, r.position.y, w, r.size.y), CURRENT)
		var label := _clock(_columns[i]["path"])
		var room := x - last_label_x > label_w and absf(x - current_x) > label_w
		if i == _current or room:
			var col := Color.WHITE if i == _current else TEXT
			draw_string(
				font,
				Vector2(x - label_w / 2, r.end.y + 15),
				label,
				HORIZONTAL_ALIGNMENT_CENTER,
				label_w,
				FONT_SIZE,
				col
			)
			last_label_x = x
		for h: float in _layout["rows"]:
			var w := _wind_at(i, h)
			if w != Vector2.INF:
				_barb(Vector2(x, _y_of(h, top_m)), w, staff)


## Wind (m/s east, north) of column `i` in the bin centred at `h_m`, or INF if missing.
func _wind_at(i: int, h_m: float) -> Vector2:
	var hs: PackedFloat32Array = _columns[i]["heights"]
	for k in hs.size():
		if absf(hs[k] - h_m) < BIN_M / 2.0:
			return _columns[i]["winds"][k]
	return Vector2.INF


## Wind barb at `p` for wind `w` (m/s east, north), staff `length` px.
func _barb(p: Vector2, w: Vector2, length: float) -> void:
	var kt := w.length() * Colormaps.KT_PER_MS
	var col := _speed_colour(kt)
	if kt < 2.5:
		draw_arc(p, 3.0, 0.0, TAU, 12, col, 1.2, true)
		return
	var d := Vector2(-w.x, w.y).normalized()  # screen direction the wind comes from
	var side := Vector2(-d.y, d.x)  # feathers towards low pressure
	var feather := length * 0.5
	var spacing := length * 0.2
	var tip := p + d * length
	draw_line(p, tip, col, 1.3, true)
	var left := int(roundf(kt / 5.0)) * 5
	var q := tip
	while left >= 50:
		var base := q - d * spacing * 1.6
		draw_colored_polygon(PackedVector2Array([q, base, q + side * feather - d * 1.0]), col)
		q = base - d * spacing * 0.5
		left -= 50
	while left >= 10:
		draw_line(q, q + side * feather + d * feather * 0.35, col, 1.3, true)
		q -= d * spacing
		left -= 10
	if left >= 5:
		if q == tip:
			q -= d * spacing  # a lone half feather sits one step in from the tip
		draw_line(q, q + (side * feather + d * feather * 0.35) * 0.5, col, 1.3, true)


static func _speed_colour(kt: float) -> Color:
	for k in range(1, SPEED_STOPS.size()):
		var a: Array = SPEED_STOPS[k - 1]
		var b: Array = SPEED_STOPS[k]
		if kt < b[0]:
			return (a[1] as Color).lerp(b[1], (kt - a[0]) / (b[0] - a[0]))
	return SPEED_STOPS[-1][1]


## "HH:MM" of a volume path.
static func _clock(path: String) -> String:
	var t := path.get_file().get_slice("_", 2)
	return "%s:%s" % [t.substr(0, 2), t.substr(2, 2)]


## Column shown nearest to the local x, or -1.
func _column_near(x: float) -> int:
	var best := -1
	for i: int in _layout.get("cols", []):
		var xi: float = _layout["x"][i]
		if best < 0 or absf(xi - x) < absf(_layout["x"][best] - x):
			best = i
	return best


## Readout for a point of the panel (local coordinates): {text}, or {} outside the plot.
func sample_at(local: Vector2) -> Dictionary:
	var r := _plot_rect()
	if _layout.is_empty() or not r.has_point(local):
		return {}
	var i := _column_near(local.x)
	if i < 0:
		return {}
	var top_m: float = _layout["top_m"]
	var h := (r.end.y - local.y) / r.size.y * top_m
	var bin_h := FIRST_BIN_M + roundf((h - FIRST_BIN_M) / BIN_M) * BIN_M
	var w := _wind_at(i, bin_h)
	var when := "%s %sZ" % [RadarLibrary.site_of(_columns[i]["path"]), _clock(_columns[i]["path"])]
	var what := "no VAD wind"
	if w != Vector2.INF:
		var ds := Hodograph.from_dir_speed(w)
		what = (
			"from %03d° at %.0f m/s (%.0f kt)"
			% [roundi(ds.x) % 360, ds.y, ds.y * Colormaps.KT_PER_MS]
		)
	return {"text": "%s   %.2f km ARL\n%s   click: go to volume" % [what, bin_h / 1000.0, when]}


func _gui_input(event: InputEvent) -> void:
	var e := event as InputEventMouseButton
	if e == null or not e.pressed or e.button_index != MOUSE_BUTTON_LEFT:
		return
	if not _plot_rect().has_point(e.position):
		return
	var i := _column_near(e.position.x)
	if i >= 0:
		frame_picked.emit(_columns[i]["path"])
		accept_event()
