class_name SectionView
extends Control
## Vertical cross-section panel: height vs distance along a line A -> B in the 2D view,
## through every tilt of one field. Each elevation band is a ColorRect drawn by
## section.gdshader over the whole plot, keeping only the pixels whose elevation angle
## falls in its band; the beam model is the same 4/3 earth radius one as cone.gdshader.
## Two modes (button in the panel): interpolate linearly between adjacent tilts (default),
## or beams only, where each tilt reaches half a beamwidth and blank means not sampled.

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
var _elevs: Array[float] = []  # tilts shown, ascending
var _tilts: Array[int] = []  # their sweep indices
var _bands: Array = []  # [tilt below, tilt above, lo_deg, hi_deg], see _bands_*()
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


## Show the section from `a` to `b` (km in the radar's local frame, +x east, +y south)
## through all tilts of `field_name` in `vol`.
func show_section(vol: RadarVolume, field_name: String, a: Vector2, b: Vector2) -> void:
	_last = [vol, field_name, a, b]
	_a = a
	_b = b
	var tilts: Array[int] = vol.tilts(field_name) if vol != null else ([] as Array[int])
	_elevs.clear()
	for i in tilts:
		_elevs.append(vol.elevation(i))
	_tilts = tilts
	var bands := _bands_interpolated() if _interpolate else _bands_beams()
	_bands = bands
	while _rects.size() < bands.size():
		_rects.append(_new_rect())
	var rng := Colormaps.range_of(field_name)
	for k in _rects.size():
		var rect := _rects[k]
		rect.visible = k < bands.size()
		if not rect.visible:
			continue
		var band: Array = bands[k]  # [tilt below, tilt above, lo_deg, hi_deg]
		var ia := tilts[band[0]]
		var ib := tilts[band[1]]
		var mat := rect.material as ShaderMaterial
		mat.set_shader_parameter("sweep_a", vol.get_texture(ia, field_name))
		mat.set_shader_parameter("sweep_b", vol.get_texture(ib, field_name))
		mat.set_shader_parameter("geom_a", _geometry(vol, ia, field_name))
		mat.set_shader_parameter("geom_b", _geometry(vol, ib, field_name))
		mat.set_shader_parameter("blend", ia != ib)
		mat.set_shader_parameter("lo_deg", band[2])
		mat.set_shader_parameter("hi_deg", band[3])
		mat.set_shader_parameter("half_beam_deg", BEAMWIDTH_DEG / 2.0)
		mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
		mat.set_shader_parameter("cmap_min", rng[0])
		mat.set_shader_parameter("cmap_max", rng[1])
		mat.set_shader_parameter("a_km", a)
		mat.set_shader_parameter("b_km", b)
		mat.set_shader_parameter("h_max_km", H_MAX_KM)
		mat.set_shader_parameter("storm_motion", storm_motion)
	_mode_button.text = "Interpolated" if _interpolate else "Beams only"
	_title = "Section A-B  %.0f km   %s   (km)" % [a.distance_to(b), field_name]
	if vol == null or tilts.is_empty():
		_title += "   (no %s in this volume)" % field_name
	_overlay.queue_redraw()


## Readout for a point of the panel (local coordinates): {t (0..1 along A -> B), text},
## or {} outside the plot. Mirrors section.gdshader: same beam model, bands and blending.
func sample_at(local: Vector2) -> Dictionary:
	var r := Rect2(_plot.position, _plot.size)
	if _last.is_empty() or not r.has_point(local) or _a == _b:
		return {}
	var vol: RadarVolume = _last[0]
	var field_name: String = _last[1]
	var t := (local.x - r.position.x) / r.size.x
	var h := (r.end.y - local.y) / r.size.y * H_MAX_KM
	var p := _a.lerp(_b, t)
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
	for band: Array in _bands:
		if elev < band[2] or elev >= band[3]:
			continue
		sampled = true
		var ia := _tilts[band[0]]
		var ib := _tilts[band[1]]
		var va := _value(vol, ia, field_name, az, slant)
		v = va
		if ia != ib:
			var vb := _value(vol, ib, field_name, az, slant)
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


func _value(vol: RadarVolume, i: int, field_name: String, az: float, slant: float) -> float:
	var v := vol.value_at(i, field_name, az, slant)
	return RadarVolume.storm_relative(v, storm_motion, az, vol.elevation(i))


## Beams only: tilt k alone, half a beamwidth either side, split at the midpoint where
## neighbouring beams overlap. [k, k, lo, hi] per tilt.
func _bands_beams() -> Array:
	var out := []
	var half := BEAMWIDTH_DEG / 2.0
	for k in _elevs.size():
		var e := _elevs[k]
		var lo := e - half
		var hi := e + half
		if k > 0:
			lo = maxf(lo, (_elevs[k - 1] + e) / 2.0)
		if k < _elevs.size() - 1:
			hi = minf(hi, (e + _elevs[k + 1]) / 2.0)
		out.append([k, k, lo, hi])
	return out


## Interpolated: between each pair of adjacent tilts, plus half a beamwidth below the
## lowest and above the highest.
func _bands_interpolated() -> Array:
	var n := _elevs.size()
	if n == 0:
		return []
	var half := BEAMWIDTH_DEG / 2.0
	var out := [[0, 0, _elevs[0] - half, _elevs[0]]]
	for k in n - 1:
		out.append([k, k + 1, _elevs[k], _elevs[k + 1]])
	out.append([n - 1, n - 1, _elevs[n - 1], _elevs[n - 1] + half])
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
	# Beam centre of every tilt along the section, split where it leaves the plot.
	for e in _elevs:
		var pts := PackedVector2Array()
		for k in BEAM_SAMPLES + 1:
			var t := float(k) / BEAM_SAMPLES
			var bh := beam_height(e, _a.lerp(_b, t).length())
			if bh <= H_MAX_KM:
				pts.append(Vector2(r.position.x + t * r.size.x, r.end.y - bh / H_MAX_KM * r.size.y))
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
