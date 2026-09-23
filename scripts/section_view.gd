class_name SectionView
extends Control
## Vertical cross-section panel: height vs distance along a line A -> B in the 2D view,
## through every tilt of one field. Each elevation band is a ColorRect drawn by
## section.gdshader over the whole plot, keeping only the pixels whose elevation angle
## falls in its band; the beam model is the same 4/3 earth radius one as cone.gdshader.
## Two modes (button in the panel): interpolate linearly between adjacent tilts (default),
## or beams only, where each tilt reaches half a beamwidth and blank means not sampled.
## In a mosaic the line is split into stretches by nearest radar (_split), each drawn from
## its own radar's tilts with the line transformed into that radar's frame.

const SECTION_SHADER := preload("res://shaders/section.gdshader")
const BEAMWIDTH_DEG := 0.95  # WSR-88D half-power beamwidth
const H_MAX_KM := 18.0
const KE_A := 8494.67  # 4/3 * 6371 km
const MARGIN_LEFT := 34.0
const MARGIN_RIGHT := 12.0
const MARGIN_TOP := 24.0
const MARGIN_BOTTOM := 22.0
const FONT_SIZE := 12
const BEAM_SAMPLES := 48
const BG := Color(0.03, 0.03, 0.06, 0.88)
const PLOT_BG := Color(0.07, 0.08, 0.11)
const GRID := Color(1, 1, 1, 0.12)
const TEXT := Color(1, 1, 1, 0.8)
const BEAM_LINE := Color(1, 1, 1, 0.18)

var storm_motion := Vector2.ZERO  # m/s east, north; zero = ground-relative
var _plot: Control
var _overlay: Control
var _rects: Array[ColorRect] = []
var _a := Vector2.ZERO
var _b := Vector2.ZERO
var _pieces: Array = []  # stretches of A-B per radar, see _split(); + tilts, elevs, bands
var _title := ""
var _interpolate := true
var _mode_button: Button
var _last: Array = []  # arguments of the last show_section(), to redraw on mode change


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP  # clicks on the panel must not move the line
	_plot = Control.new()
	_plot.clip_contents = true
	_plot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_plot.set_anchors_preset(Control.PRESET_FULL_RECT)
	_plot.offset_left = MARGIN_LEFT
	_plot.offset_right = -MARGIN_RIGHT
	_plot.offset_top = MARGIN_TOP
	_plot.offset_bottom = -MARGIN_BOTTOM
	add_child(_plot)
	var bg := ColorRect.new()
	bg.color = PLOT_BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_plot.add_child(bg)
	_overlay = Control.new()
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.draw.connect(_draw_overlay)
	add_child(_overlay)
	_mode_button = Button.new()
	_mode_button.focus_mode = Control.FOCUS_NONE
	_mode_button.add_theme_font_size_override("font_size", 11)
	_mode_button.tooltip_text = "Interpolate between tilts, or show each beam only"
	_mode_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_mode_button.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_mode_button.offset_right = -MARGIN_RIGHT
	_mode_button.offset_top = 1
	_mode_button.pressed.connect(
		func() -> void:
			_interpolate = not _interpolate
			if not _last.is_empty():
				show_section.callv(_last)
	)
	add_child(_mode_button)


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BG)


## Show the section from `a` to `b` (km in the selected radar's local frame, +x east, +y
## south) through all tilts of `field_name` in `vol`. With mosaic `neighbors` (main.gd's
## entries: volume, offset_km, rotation) each stretch of the line is drawn by the radar
## nearest to it, as the plan view composites.
func show_section(
	vol: RadarVolume, field_name: String, a: Vector2, b: Vector2, neighbors: Array = []
) -> void:
	_last = [vol, field_name, a, b, neighbors]
	_a = a
	_b = b
	_pieces = _split(vol, a, b, neighbors) if vol != null else []
	var n_rects := 0
	var rng := Colormaps.range_of(field_name)
	var sites := PackedStringArray()
	for piece: Dictionary in _pieces:
		var pv: RadarVolume = piece["volume"]
		var tilts: Array[int] = pv.tilts(field_name)
		var elevs: Array[float] = []
		for i in tilts:
			elevs.append(pv.elevation(i))
		piece["tilts"] = tilts
		piece["elevs"] = elevs
		piece["bands"] = _bands_interpolated(elevs) if _interpolate else _bands_beams(elevs)
		if not sites.has(pv.icao()):
			sites.append(pv.icao())
		for band: Array in piece["bands"]:  # [tilt below, tilt above, lo_deg, hi_deg]
			if _rects.size() <= n_rects:
				_rects.append(_new_rect())
			var rect := _rects[n_rects]
			n_rects += 1
			rect.visible = true
			var ia := tilts[band[0]]
			var ib := tilts[band[1]]
			var mat := rect.material as ShaderMaterial
			mat.set_shader_parameter("sweep_a", pv.get_texture(ia, field_name))
			mat.set_shader_parameter("sweep_b", pv.get_texture(ib, field_name))
			mat.set_shader_parameter("geom_a", _geometry(pv, ia, field_name))
			mat.set_shader_parameter("geom_b", _geometry(pv, ib, field_name))
			mat.set_shader_parameter("blend", ia != ib)
			mat.set_shader_parameter("lo_deg", band[2])
			mat.set_shader_parameter("hi_deg", band[3])
			mat.set_shader_parameter("half_beam_deg", BEAMWIDTH_DEG / 2.0)
			mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
			mat.set_shader_parameter("cmap_min", rng[0])
			mat.set_shader_parameter("cmap_max", rng[1])
			mat.set_shader_parameter("a_km", piece["a"])
			mat.set_shader_parameter("b_km", piece["b"])
			mat.set_shader_parameter("t_min", piece["t0"])
			mat.set_shader_parameter("t_max", piece["t1"] if piece["t1"] < 1.0 else 2.0)
			mat.set_shader_parameter("h_max_km", H_MAX_KM)
			mat.set_shader_parameter("storm_motion", piece["storm"])
	for k in range(n_rects, _rects.size()):
		_rects[k].visible = false
	_mode_button.text = "Interpolated" if _interpolate else "Beams only"
	_title = "Section A-B  %.0f km   %s   (km)" % [a.distance_to(b), field_name]
	if sites.size() > 1:
		_title += "   " + ", ".join(sites)
	if n_rects == 0:
		_title += "   (no %s in this volume)" % field_name
	_overlay.queue_redraw()


## The stretches of A -> B nearest to each radar: [{volume, a, b (in that radar's frame), t0,
## t1, storm}], in order along the line. Boundaries are found by bisection between samples.
func _split(vol: RadarVolume, a: Vector2, b: Vector2, neighbors: Array) -> Array:
	var radars := [{"volume": vol, "pos": Vector2.ZERO, "rot": 0.0}]
	for n in neighbors:
		var off: Vector2 = n["offset_km"]
		radars.append({"volume": n["volume"], "pos": Vector2(off.x, -off.y), "rot": n["rotation"]})
	var nearest := func(t: float) -> int:
		var p := a.lerp(b, t)
		var best := 0
		for k in radars.size():
			if p.distance_to(radars[k]["pos"]) < p.distance_to(radars[best]["pos"]):
				best = k
		return best
	var runs := []  # [radar, t0]
	var prev: int = nearest.call(0.0)
	runs.append([prev, 0.0])
	var n_samples := 256
	for s in range(1, n_samples + 1):
		var t := float(s) / n_samples
		var k: int = nearest.call(t)
		if k == prev:
			continue
		var lo := float(s - 1) / n_samples
		var hi := t
		for _i in 24:
			var mid := 0.5 * (lo + hi)
			if nearest.call(mid) == prev:
				lo = mid
			else:
				hi = mid
		runs.append([k, hi])
		prev = k
	var out := []
	for j in runs.size():
		var r: Dictionary = radars[runs[j][0]]
		var pos: Vector2 = r["pos"]
		var rot: float = r["rot"]
		(
			out
			. append(
				{
					"volume": r["volume"],
					"a": (a - pos).rotated(-rot),
					"b": (b - pos).rotated(-rot),
					"t0": runs[j][1],
					"t1": runs[j + 1][1] if j + 1 < runs.size() else 1.0,
					"storm": storm_motion.rotated(rot),
				}
			)
		)
	return out


## Readout for a point of the panel (local coordinates): {t (0..1 along A -> B), text},
## or {} outside the plot. Mirrors section.gdshader: same beam model, bands and blending.
func sample_at(local: Vector2) -> Dictionary:
	var r := Rect2(_plot.position, _plot.size)
	if _pieces.is_empty() or not r.has_point(local) or _a == _b:
		return {}
	var field_name: String = _last[1]
	var t := (local.x - r.position.x) / r.size.x
	var h := (r.end.y - local.y) / r.size.y * H_MAX_KM
	var piece: Dictionary = _pieces[-1]
	for pc: Dictionary in _pieces:
		if t < pc["t1"]:
			piece = pc
			break
	var vol: RadarVolume = piece["volume"]
	var p: Vector2 = (piece["a"] as Vector2).lerp(piece["b"], t)
	var s := p.length()
	var phi := s / KE_A
	var x := (KE_A + h) * sin(phi)
	var half_phi := sin(0.5 * phi)
	var z := h * cos(phi) - 2.0 * KE_A * half_phi * half_phi
	var elev := rad_to_deg(atan2(z, x))
	var slant := sqrt(x * x + z * z)
	var az := fposmod(rad_to_deg(atan2(p.x, -p.y)), 360.0)
	var where := (
		"%.1f km ARL   %.0f km along A-B   %.0f km @ %03d° from %s   elev %.2f°"
		% [h, t * _a.distance_to(_b), s, roundi(az) % 360, vol.icao(), elev]
	)
	var v := RadarVolume.MISSING
	var sampled := false
	var tilts: Array[int] = piece["tilts"]
	for band: Array in piece["bands"]:
		if elev < band[2] or elev >= band[3]:
			continue
		sampled = true
		var ia := tilts[band[0]]
		var ib := tilts[band[1]]
		var storm: Vector2 = piece["storm"]
		var va := _value(vol, ia, field_name, az, slant, storm)
		v = va
		if ia != ib:
			var vb := _value(vol, ib, field_name, az, slant, storm)
			var ea := vol.elevation(ia)
			var eb := vol.elevation(ib)
			var w := (elev - ea) / (eb - ea)
			var half := BEAMWIDTH_DEG / 2.0
			if va > -900.0 and vb > -900.0:
				v = lerpf(va, vb, w)
			elif va > -900.0 and elev - ea < half:
				v = va
			elif vb > -900.0 and eb - elev < half:
				v = vb
			else:
				v = va if w < 0.5 else vb
				v = v if v < -1500.0 else RadarVolume.MISSING
		break
	var value := Colormaps.format_value(field_name, v) if sampled else "not sampled"
	return {"t": t, "text": "%s  %s\n%s" % [field_name, value, where]}


static func _value(
	vol: RadarVolume, i: int, field_name: String, az: float, slant: float, storm: Vector2
) -> float:
	var v := vol.value_at(i, field_name, az, slant)
	return RadarVolume.storm_relative(v, storm, az, vol.elevation(i))


## Beams only: tilt k alone, half a beamwidth either side, split at the midpoint where
## neighbouring beams overlap. [k, k, lo, hi] per tilt.
static func _bands_beams(elevs: Array[float]) -> Array:
	var out := []
	var half := BEAMWIDTH_DEG / 2.0
	for k in elevs.size():
		var e := elevs[k]
		var lo := e - half
		var hi := e + half
		if k > 0:
			lo = maxf(lo, (elevs[k - 1] + e) / 2.0)
		if k < elevs.size() - 1:
			hi = minf(hi, (e + elevs[k + 1]) / 2.0)
		out.append([k, k, lo, hi])
	return out


## Interpolated: between each pair of adjacent tilts, plus half a beamwidth below the
## lowest and above the highest.
static func _bands_interpolated(elevs: Array[float]) -> Array:
	var n := elevs.size()
	if n == 0:
		return []
	var half := BEAMWIDTH_DEG / 2.0
	var out := [[0, 0, elevs[0] - half, elevs[0]]]
	for k in n - 1:
		out.append([k, k + 1, elevs[k], elevs[k + 1]])
	out.append([n - 1, n - 1, elevs[n - 1], elevs[n - 1] + half])
	return out


## Tilt geometry for section.gdshader: elevation, first gate centre (km), spacing (km), gates.
static func _geometry(vol: RadarVolume, i: int, field_name: String) -> Vector4:
	var f: Dictionary = vol.sweep(i)["fields"][field_name]
	return Vector4(
		vol.elevation(i),
		float(f["first_gate_m"]) / 1000.0,
		float(f["gate_spacing_m"]) / 1000.0,
		float(f["n_gates"])
	)


func _new_rect() -> ColorRect:
	var rect := ColorRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mat := ShaderMaterial.new()
	mat.shader = SECTION_SHADER
	rect.material = mat
	_plot.add_child(rect)
	return rect


## Beam-centre height (km) of elevation `elev_deg` at ground range `s_km`, 4/3 earth.
static func beam_height(elev_deg: float, s_km: float) -> float:
	var th := deg_to_rad(elev_deg)
	var c := cos(th + s_km / KE_A)
	return KE_A * (cos(th) / c - 1.0) if c > 0.0 else INF


func _draw_overlay() -> void:
	var font := ThemeDB.fallback_font
	var r := Rect2(_plot.position, _plot.size)
	var length := _a.distance_to(_b)
	_overlay.draw_string(font, Vector2(8, 16), _title, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TEXT)
	if r.size.x <= 0 or r.size.y <= 0:
		return
	# Height grid and labels.
	var h_step := _nice_step(H_MAX_KM, 5)
	var h := 0.0
	while h <= H_MAX_KM + 0.01:
		var y := r.end.y - h / H_MAX_KM * r.size.y
		_overlay.draw_line(Vector2(r.position.x, y), Vector2(r.end.x, y), GRID)
		_overlay.draw_string(
			font,
			Vector2(4, y + 4),
			str(int(h)),
			HORIZONTAL_ALIGNMENT_RIGHT,
			MARGIN_LEFT - 8,
			FONT_SIZE,
			TEXT
		)
		h += h_step
	# Distance ticks along A -> B.
	if length > 0.0:
		var d_step := _nice_step(length, 8)
		var d := 0.0
		while d <= length + 0.01:
			var x := r.position.x + d / length * r.size.x
			_overlay.draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), GRID)
			_overlay.draw_string(
				font,
				Vector2(x - 20, r.end.y + 15),
				str(int(d)),
				HORIZONTAL_ALIGNMENT_CENTER,
				40,
				FONT_SIZE,
				TEXT
			)
			d += d_step
	_overlay.draw_string(font, Vector2(8, r.end.y + 15), "A", 0, -1, 13, TEXT)
	_overlay.draw_string(font, Vector2(r.end.x + 2, r.end.y + 15), "B", 0, -1, 13, TEXT)
	# Beam centre of every tilt along the section (each radar over its own stretch), split
	# where it leaves the plot; a thin mark where the radar changes.
	for piece: Dictionary in _pieces:
		var t0: float = piece["t0"]
		var t1: float = piece["t1"]
		if t0 > 0.0:
			var x0 := r.position.x + t0 * r.size.x
			_overlay.draw_line(Vector2(x0, r.position.y), Vector2(x0, r.end.y), BEAM_LINE * 2.0)
		for e: float in piece["elevs"]:
			var pts := PackedVector2Array()
			for k in BEAM_SAMPLES + 1:
				var t := lerpf(t0, t1, float(k) / BEAM_SAMPLES)
				var bh := beam_height(e, (piece["a"] as Vector2).lerp(piece["b"], t).length())
				if bh <= H_MAX_KM:
					pts.append(
						Vector2(r.position.x + t * r.size.x, r.end.y - bh / H_MAX_KM * r.size.y)
					)
				if pts.size() > 1 and (bh > H_MAX_KM or k == BEAM_SAMPLES):
					_overlay.draw_polyline(pts, BEAM_LINE)
				if bh > H_MAX_KM:
					pts.clear()


## Smallest of 1, 2, 5 x 10^n giving at most `max_ticks` steps over `span`.
static func _nice_step(span: float, max_ticks: int) -> float:
	var step := 1.0
	while span / step > max_ticks:
		for m in [2.0, 2.5, 2.0]:
			step *= m
			if span / step <= max_ticks:
				break
	return step
