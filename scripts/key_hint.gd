class_name KeyHint
extends Control
## The key hint at the bottom left: keycaps with what they do, wrapped into rows on a dim
## panel. Shows the essential keys; H (or clicking the last item) expands it to every key.
##
## Items are [keys: Array[String], label: String]; a null item starts a new row (expanded
## list only). Arrow keys are drawn as triangles; mouse actions (MOUSE) get pill-shaped caps.
## Drawn in code rather than built from Labels so measure() can wrap it for any width,
## visible or not (Hud._layout() sizes and hides it by that height).

signal expanded_changed

const MOUSE := ["Wheel", "Drag", "Left drag", "Right drag", "Hover", "Click"]
const ARROWS := {"Left": PI, "Right": 0.0, "Up": -PI / 2.0, "Down": PI / 2.0}
const FONT_SIZE := 12
const CAP_FONT_SIZE := 11
const CAP_HEIGHT := 18.0
const CAP_PAD := 5.0
const CAP_GAP := 3.0  # between the caps of one item
const LABEL_GAP := 5.0  # caps to label
const ITEM_GAP := 14.0
const ROW_GAP := 5.0
const PAD := Vector2(8, 6)
const BG := Color(0.03, 0.03, 0.06, 0.72)
const CAP_FILL := Color(1, 1, 1, 0.1)
const CAP_EDGE := Color(1, 1, 1, 0.3)
const CAP_TEXT := Color(1, 1, 1, 0.92)
const LABEL_TEXT := Color(1, 1, 1, 0.62)
const TOGGLE_TEXT := Color(0.55, 0.8, 1.0, 0.9)
## Droplet's keys and mouse actions, see items_for().
const HINT_ESSENTIAL := [
	[["Space"], "play"],
	[["Left", "Right"], "step"],
	[["Up", "Down"], "tilt"],
	[["1–8"], "field"],
	[["V"], "2D/3D"],
]
const HINT_ALL := [
	[["Space"], "play"],
	[["Left", "Right"], "step"],
	[["Shift", "Left", "Right"], "prev/next loop"],
	[["Home", "End"], "first/last"],
	[["[", "]"], "speed"],
	[["L"], "live"],
	null,
	[["Up", "Down"], "tilt"],
	[["1–8"], "field"],
	[["9"], "products"],
	[["0"], "KDP/shear/HCA"],
	[["S"], "site"],
	[["V"], "2D/3D"],
	[["R"], "reset view"],
	null,
	[["M"], "mosaic"],
	[["A"], "warnings"],
	[["O"], "SPC outlook"],
	[["C"], "cells"],
	[["X"], "section"],
	[["T"], "storm-relative"],
	[["W"], "hodograph"],
	[["P"], "VWP"],
	[["F"], "fetch"],
	[["E"], "export loop"],
	null,
]
const HINT_2D := [[["Wheel"], "zoom"], [["Drag"], "pan"], [["Hover"], "value"]]
const HINT_SECTION := [
	[["Wheel"], "zoom"],
	[["Left drag"], "section A to B"],
	[["Right drag"], "pan"],
	[["Hover"], "value"],
]
const HINT_3D := [[["Left drag"], "orbit"], [["Right drag"], "pan"], [["Wheel"], "zoom"]]
const HINT_3D_KEYS := [
	[["B"], "cones/volume"],
	[["I"], "isolate tilts"],
	[[",", "."], "threshold"],
	[["-", "="], "volume opacity"],
	[["PgUp", "PgDn"], "height exaggeration"],
]
const HINT_OVERVIEW := [
	[["Click"], "a radar marker to see its latest scans"], [["Wheel"], "zoom"], [["Drag"], "pan"]
]

var expanded := false
var _essential: Array = []
var _all: Array = []
var _placed: Array = []  # [item, position] from the last _flow() at the control's width
var _toggle_rect := Rect2()
var _cap_box: StyleBoxFlat
var _pill_box: StyleBoxFlat
var _bg_box: StyleBoxFlat


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP  # only over the toggle, see _has_point()
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_cap_box = _box(CAP_FILL, 3)
	_cap_box.border_color = CAP_EDGE
	_cap_box.set_border_width_all(1)
	_cap_box.border_width_bottom = 2  # a little depth, like a key
	_pill_box = _box(Color(1, 1, 1, 0.06), int(CAP_HEIGHT / 2.0))
	_pill_box.border_color = Color(1, 1, 1, 0.22)
	_pill_box.set_border_width_all(1)
	_bg_box = _box(BG, 5)
	resized.connect(queue_redraw)


## [essential, all] items for the current mode.
static func items_for(overview: bool, view_3d: bool, section_on: bool) -> Array:
	if overview:
		return [HINT_OVERVIEW, []]
	if view_3d:
		return [HINT_ESSENTIAL + HINT_3D, HINT_ALL + HINT_3D + [null] + HINT_3D_KEYS]
	var mouse: Array = HINT_SECTION if section_on else HINT_2D
	return [HINT_ESSENTIAL + mouse, HINT_ALL + mouse]


## `essential` is shown collapsed; `all` expanded (empty: nothing more, no toggle).
func set_items(essential: Array, all: Array) -> void:
	if essential == _essential and all == _all:
		return
	_essential = essential
	_all = all
	queue_redraw()


func set_expanded(on: bool) -> void:
	if expanded != on and not _all.is_empty():
		expanded = on
		queue_redraw()
		expanded_changed.emit()


## Height of the hint wrapped to `width`, panel padding included.
func measure(width: float) -> float:
	return _flow(width)[1]


func _items() -> Array:
	var items: Array = (_all if expanded else _essential).duplicate()
	if not _all.is_empty():
		items.append([["H"], "fewer keys" if expanded else "all keys"])
	return items


## Wraps the items to `width`: returns [[item, position]...], height, and the panel width
## (the widest row).
func _flow(width: float) -> Array:
	var placed: Array = []
	var inner := width - 2.0 * PAD.x
	var x := 0.0
	var y := 0.0
	var widest := 0.0
	for item: Variant in _items():
		if item == null:
			if x > 0.0:
				x = 0.0
				y += CAP_HEIGHT + ROW_GAP
			continue
		var w := _item_width(item)
		if x > 0.0 and x + ITEM_GAP + w > inner:
			x = 0.0
			y += CAP_HEIGHT + ROW_GAP
		if x > 0.0:
			x += ITEM_GAP
		placed.append([item, PAD + Vector2(x, y)])
		x += w
		widest = maxf(widest, x)
	var h := y + CAP_HEIGHT + 2.0 * PAD.y if not placed.is_empty() else 0.0
	return [placed, h, widest + 2.0 * PAD.x]


func _item_width(item: Array) -> float:
	var w := 0.0
	for k: String in item[0]:
		w += _cap_width(k) + CAP_GAP
	return w - CAP_GAP + LABEL_GAP + _font().get_string_size(item[1], 0, -1, FONT_SIZE).x


func _cap_width(key: String) -> float:
	if ARROWS.has(key):
		return CAP_HEIGHT
	var text_w := _font().get_string_size(key, 0, -1, CAP_FONT_SIZE).x
	var pad := CAP_PAD + (2.0 if key in MOUSE else 0.0)
	return maxf(CAP_HEIGHT, text_w + 2.0 * pad)


func _draw() -> void:
	var flow := _flow(size.x)
	_placed = flow[0]
	_toggle_rect = Rect2()
	if _placed.is_empty():
		return
	# Anchored at the bottom: the panel's top is where the wrapped rows end.
	var top := size.y - float(flow[1])
	draw_style_box(_bg_box, Rect2(0, top, flow[2], flow[1]))
	var font := _font()
	var toggle: Variant = _items()[-1] if not _all.is_empty() else null
	for p: Array in _placed:
		var item: Array = p[0]
		var pos: Vector2 = p[1] + Vector2(0, top)
		var x := pos.x
		for k: String in item[0]:
			var w := _cap_width(k)
			_draw_cap(k, Rect2(x, pos.y, w, CAP_HEIGHT))
			x += w + CAP_GAP
		x += LABEL_GAP - CAP_GAP
		var baseline := pos.y + (CAP_HEIGHT + font.get_ascent(FONT_SIZE)) / 2.0 - 1.0
		var colour := TOGGLE_TEXT if item == toggle else LABEL_TEXT
		draw_string(font, Vector2(x, baseline), item[1], 0, -1, FONT_SIZE, colour)
		if item == toggle:
			_toggle_rect = Rect2(pos, Vector2(_item_width(item), CAP_HEIGHT)).grow(3)


func _draw_cap(key: String, r: Rect2) -> void:
	draw_style_box(_pill_box if key in MOUSE else _cap_box, r)
	var c := r.get_center() - Vector2(0, 0.5)  # the thicker bottom edge
	if ARROWS.has(key):
		var a: float = ARROWS[key]
		var pts := PackedVector2Array()
		for p in [Vector2(3.5, 0), Vector2(-2.5, -3.5), Vector2(-2.5, 3.5)]:
			pts.append(c + p.rotated(a))
		draw_colored_polygon(pts, CAP_TEXT)
		return
	var font := _font()
	var w := font.get_string_size(key, 0, -1, CAP_FONT_SIZE).x
	var baseline := c.y + (font.get_ascent(CAP_FONT_SIZE) - font.get_descent(CAP_FONT_SIZE)) / 2.0
	draw_string(font, Vector2(c.x - w / 2.0, baseline), key, 0, -1, CAP_FONT_SIZE, CAP_TEXT)


func _has_point(point: Vector2) -> bool:
	return _toggle_rect.has_point(point)


func _gui_input(event: InputEvent) -> void:
	var b := event as InputEventMouseButton
	if b != null and b.pressed and b.button_index == MOUSE_BUTTON_LEFT:
		set_expanded(not expanded)
		accept_event()


func _font() -> Font:
	return get_theme_font("font", "Label")


func _box(colour: Color, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = colour
	s.set_corner_radius_all(radius)
	s.anti_aliasing = true
	return s
