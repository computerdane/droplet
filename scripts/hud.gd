class_name Hud
extends Control
## On-screen controls: info text, site picker, 2D/3D toggle, field buttons, colour legend and
## a playback bar. Built in code; emits intent signals and main.gd pushes state back via
## the set_* methods. Nothing here takes keyboard focus, so shortcuts keep working, except
## the text fields of the fetch panel while it is open.
##
## Layout adapts to the canvas size (main.gd keeps the UI scale >= 1, so small windows get
## a smaller canvas rather than tiny text), see _layout(): the top-right rows wrap when the
## info text leaves little room, the hodograph and cross-section panels are sized from the
## space left and go side by side when they do not fit stacked, and the key hint wraps next
## to them or hides when there is no room.

signal play_toggled
signal step_requested(delta: int)
signal scrubbed(frame_in_sequence: int)
signal speed_selected(fps: float)
signal live_toggled
signal site_selected(site: String)
signal view_toggled
signal mosaic_toggled
signal section_toggled
signal fetch_toggled
signal srm_toggled
signal srm_auto_toggled
signal winds_toggled
signal vwp_toggled
signal srm_changed(d_from_deg: float, d_speed: float)
signal field_selected(field_name: String)

const SPEEDS := [1.0, 2.0, 4.0, 8.0, 15.0]
const DEFAULT_SPEED_INDEX := 2
const PRODUCT_NAMES := {
	"CREF": "composite reflectivity",
	"ET": "18 dBZ echo top",
	"VIL": "vertically integrated liquid",
}
const LEGEND_WIDTH := 280
const HODOGRAPH_SIZE := Vector2(280, 300)  # largest; shrinks to fit
const HODOGRAPH_MIN_H := 180.0
const SECTION_MIN := Vector2(340, 170)
const SECTION_MAX := Vector2(760, 360)
const SECTION_WIDTH_SHARE := 0.42  # of the canvas width
const SECTION_ASPECT := 0.48  # height / width
const MARGIN := 12.0
const GAP := 8.0
const VWP_MIN := Vector2(240, 150)
const VWP_MAX := Vector2(640, 300)
const VWP_WIDTH_SHARE := 0.4
const VWP_ASPECT := 0.45
const READOUT_OFFSET := Vector2(18, 18)
const COLUMN_MIN_WIDTH := 300.0
const HINT_MIN_WIDTH := 240.0

var info: Label
var hint: Label
var site_option: OptionButton
var view_button: Button
var mosaic_button: Button
var section_button: Button
var section: SectionView
var fetch_panel: FetchPanel
var field_buttons: Dictionary = {}  # name -> Button
var srm_row: HFlowContainer
var srm_button: Button
var srm_auto_button: Button
var winds_button: Button
var hodograph: Hodograph
var vwp_button: Button
var vwp: WindProfileView
var readout: PanelContainer
var readout_label: Label
var srm_dir_label: Label
var srm_speed_label: Label
var legend_tex: TextureRect
var legend_lo: Label
var legend_hi: Label
var legend_unit: Label
var play_button: Button
var slider: HSlider
var time_label: Label
var speed_option: OptionButton
var live_button: Button
var _top_box: VBoxContainer
var _top_rows: Array[HFlowContainer] = []
var _bar: PanelContainer
var _layout_queued := false
var _sites: Array[String] = []
var _setting_slider := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_info()
	_build_top_right()
	_build_bottom_bar()
	_build_section()
	_build_readout()
	fetch_panel = FetchPanel.new()
	fetch_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	fetch_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	fetch_panel.offset_top = 60
	fetch_panel.visible = false
	add_child(fetch_panel)
	resized.connect(_queue_layout)
	info.minimum_size_changed.connect(_queue_layout)
	_top_box.resized.connect(_queue_layout)
	_bar.resized.connect(_queue_layout)
	_queue_layout()


func _build_info() -> void:
	info = _label(14)
	info.position = Vector2(12, 10)
	add_child(info)
	hint = _label(12)
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(hint)


func _build_top_right() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.offset_left = -MARGIN
	box.offset_right = -MARGIN
	box.offset_top = 10
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)
	_top_box = box

	var row := _flow(box)
	site_option = OptionButton.new()
	site_option.focus_mode = Control.FOCUS_NONE
	site_option.tooltip_text = "Radar site (sites with decoded volumes)"
	site_option.item_selected.connect(func(i: int) -> void: site_selected.emit(_sites[i]))
	row.add_child(site_option)
	var fetch := _button("Fetch", "Download a site / time range, or follow a site live (F)")
	fetch.pressed.connect(fetch_toggled.emit)
	row.add_child(fetch)
	mosaic_button = _button("Mosaic", "Also draw other sites at the same time (M)")
	mosaic_button.toggle_mode = true
	mosaic_button.pressed.connect(mosaic_toggled.emit)
	row.add_child(mosaic_button)
	section_button = _button("Section", "Vertical cross-section: drag A to B in the 2D view (X)")
	section_button.toggle_mode = true
	section_button.pressed.connect(section_toggled.emit)
	row.add_child(section_button)
	winds_button = _button("Winds", "VAD wind profile hodograph and storm motion (W)")
	winds_button.toggle_mode = true
	winds_button.pressed.connect(winds_toggled.emit)
	row.add_child(winds_button)
	vwp_button = _button("VWP", "VAD wind profile over the loop, as wind barbs (P)")
	vwp_button.toggle_mode = true
	vwp_button.pressed.connect(vwp_toggled.emit)
	row.add_child(vwp_button)
	view_button = _button("3D", "Toggle 2D plan view / 3D volume (V)")
	view_button.pressed.connect(view_toggled.emit)
	row.add_child(view_button)

	var fields := _flow(box)
	var group := ButtonGroup.new()
	var names: Array = RadarVolume.FIELDS + RadarVolume.PRODUCTS
	for i in names.size():
		var fname: String = names[i]
		var tip := "%s (%d)" % [fname, i + 1]
		if fname in RadarVolume.PRODUCTS:
			tip = "%s: %s, plan view only (9 cycles products)" % [fname, PRODUCT_NAMES[fname]]
		var b := _button(fname, tip)
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: field_selected.emit(fname))
		fields.add_child(b)
		field_buttons[fname] = b

	_build_srm_row(box)

	legend_tex = TextureRect.new()
	legend_tex.custom_minimum_size = Vector2(LEGEND_WIDTH, 12)
	legend_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	legend_tex.stretch_mode = TextureRect.STRETCH_SCALE
	legend_tex.size_flags_horizontal = Control.SIZE_SHRINK_END
	box.add_child(legend_tex)
	var labels := _hbox()
	labels.custom_minimum_size = Vector2(LEGEND_WIDTH, 0)
	labels.size_flags_horizontal = Control.SIZE_SHRINK_END
	box.add_child(labels)
	legend_lo = _label(12)
	legend_unit = _label(12)
	legend_unit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	legend_unit.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	legend_hi = _label(12)
	labels.add_child(legend_lo)
	labels.add_child(legend_unit)
	labels.add_child(legend_hi)

	hodograph = Hodograph.new()
	hodograph.size = HODOGRAPH_SIZE
	hodograph.visible = false
	add_child(hodograph)


## Storm-relative motion controls, shown for velocity fields: storm moving from a
## direction (meteorological convention) at a speed.
## The row wraps between its three groups, never inside one.
func _build_srm_row(box: VBoxContainer) -> void:
	srm_row = _flow(box)
	var toggles := _hbox()
	srm_row.add_child(toggles)
	srm_button = _button("Storm-relative", "Subtract the storm motion from velocity (T)")
	srm_button.toggle_mode = true
	srm_button.pressed.connect(srm_toggled.emit)
	toggles.add_child(srm_button)
	srm_auto_button = _button(
		"Auto", "Storm motion from the VAD wind profile (Bunkers right mover)"
	)
	srm_auto_button.toggle_mode = true
	srm_auto_button.pressed.connect(srm_auto_toggled.emit)
	toggles.add_child(srm_auto_button)
	var dir := _hbox()
	srm_row.add_child(dir)
	dir.add_child(_srm_step("<", "Storm motion from 10 degrees further left", -10.0, 0.0))
	srm_dir_label = _label(13)
	srm_dir_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dir.add_child(srm_dir_label)
	dir.add_child(_srm_step(">", "Storm motion from 10 degrees further right", 10.0, 0.0))
	var speed := _hbox()
	srm_row.add_child(speed)
	speed.add_child(_srm_step("-", "Storm slower by 1 m/s", 0.0, -1.0))
	srm_speed_label = _label(13)
	srm_speed_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	speed.add_child(srm_speed_label)
	speed.add_child(_srm_step("+", "Storm faster by 1 m/s", 0.0, 1.0))


func _srm_step(text: String, tip: String, d_from_deg: float, d_speed: float) -> Button:
	var b := _button(text, tip)
	b.pressed.connect(func() -> void: srm_changed.emit(d_from_deg, d_speed))
	return b


func _build_bottom_bar() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.03, 0.06, 0.8)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	_bar = panel

	var row := _hbox()
	panel.add_child(row)
	var prev := _button("<", "Previous volume in this loop (Left; Shift+Left: previous loop)")
	prev.pressed.connect(func() -> void: step_requested.emit(-1))
	row.add_child(prev)
	play_button = _button("Play", "Play / pause the loop (Space)")
	play_button.custom_minimum_size.x = 64
	play_button.pressed.connect(play_toggled.emit)
	row.add_child(play_button)
	var next := _button(">", "Next volume in this loop (Right; Shift+Right: next loop)")
	next.pressed.connect(func() -> void: step_requested.emit(1))
	row.add_child(next)

	slider = HSlider.new()
	slider.focus_mode = Control.FOCUS_NONE
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.step = 1
	slider.tooltip_text = "Volumes in this sequence (gaps > 30 min split sequences)"
	slider.value_changed.connect(_on_slider)
	row.add_child(slider)

	time_label = _label(14)
	time_label.custom_minimum_size.x = 220
	row.add_child(time_label)

	speed_option = OptionButton.new()
	speed_option.focus_mode = Control.FOCUS_NONE
	speed_option.tooltip_text = "Loop speed, volumes per second ([ and ])"
	for s in SPEEDS:
		speed_option.add_item("%s fps" % str(s))
	speed_option.select(DEFAULT_SPEED_INDEX)
	speed_option.item_selected.connect(func(i: int) -> void: speed_selected.emit(SPEEDS[i]))
	row.add_child(speed_option)

	live_button = _button("LIVE", "Follow the newest volume (L)")
	live_button.toggle_mode = true
	live_button.pressed.connect(live_toggled.emit)
	row.add_child(live_button)


## Cross-section panel (bottom right) and VWP (bottom left) above the playback bar;
## placed by _layout().
func _build_section() -> void:
	section = SectionView.new()
	section.visible = false
	add_child(section)
	vwp = WindProfileView.new()
	vwp.visible = false
	add_child(vwp)


## Hover readout next to the mouse; drawn last so it sits over the panels.
func _build_readout() -> void:
	readout = PanelContainer.new()
	readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	readout.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.02, 0.02, 0.04, 0.85)
	style.set_content_margin_all(6)
	style.set_corner_radius_all(3)
	readout.add_theme_stylebox_override("panel", style)
	readout_label = _label(12)
	readout.add_child(readout_label)
	add_child(readout)


func _queue_layout() -> void:
	if not _layout_queued:
		_layout_queued = true
		_layout.call_deferred()


## Places the top-right column, hodograph, cross-section and hint for the current canvas
## size. Positions are in canvas units (after UI scaling).
func _layout() -> void:
	_layout_queued = false
	var view := size
	var bar_top := view.y - _bar.size.y
	var info_bottom := info.position.y + info.get_combined_minimum_size().y

	# Top-right column: as wide as its rows want, but leave the info text its room (the rows
	# wrap then). Only below COLUMN_MIN_WIDTH does it give up and overlap the info text.
	var natural := LEGEND_WIDTH * 1.0
	for r in _top_rows:
		if r.visible:
			natural = maxf(natural, _natural_width(r))
	var room := view.x - info.position.x - info.get_combined_minimum_size().x - 3 * MARGIN
	var col_w := minf(natural, maxf(room, COLUMN_MIN_WIDTH))
	col_w = minf(col_w, view.x - 2 * MARGIN)
	_top_box.custom_minimum_size.x = col_w
	var legend_w := minf(LEGEND_WIDTH, col_w)
	legend_tex.custom_minimum_size.x = legend_w
	legend_lo.get_parent().custom_minimum_size.x = legend_w
	var top := _top_box.position.y + _top_box.get_combined_minimum_size().y + GAP
	var bottom := bar_top - GAP
	var right := view.x - MARGIN

	# Hodograph under the column, cross-section at the bottom right; side by side when
	# stacking them would squeeze the hodograph below HODOGRAPH_MIN_H.
	var sec := Vector2.ZERO
	if section.visible:
		sec.x = clampf(view.x * SECTION_WIDTH_SHARE, SECTION_MIN.x, SECTION_MAX.x)
		sec.y = clampf(sec.x * SECTION_ASPECT, SECTION_MIN.y, SECTION_MAX.y)
	var hodo := Vector2.ZERO
	var side_by_side := false
	if hodograph.visible:
		var hodo_w := minf(HODOGRAPH_SIZE.x, col_w)
		var avail := bottom - top
		if section.visible and avail - sec.y - GAP < HODOGRAPH_MIN_H:
			side_by_side = true
		elif section.visible:
			avail -= sec.y + GAP
		hodo = Vector2(hodo_w, clampf(avail, HODOGRAPH_MIN_H, HODOGRAPH_SIZE.y))
		hodograph.position = Vector2(right - hodo.x, top)
		hodograph.size = hodo
	if section.visible:
		var sec_right := right - (hodo.x + GAP if side_by_side else 0.0)
		sec.x = minf(sec.x, sec_right - MARGIN)
		sec.y = minf(sec.y, bottom - info_bottom - GAP)
		section.position = Vector2(sec_right - sec.x, bottom - sec.y)
		section.size = sec

	# VWP at the bottom left, as wide as the room left of the cross-section allows.
	var hint_bottom := bottom
	if vwp.visible:
		var vw := clampf(view.x * VWP_WIDTH_SHARE, VWP_MIN.x, VWP_MAX.x)
		var vwp_right := right
		if section.visible:
			vwp_right = section.position.x - GAP
		elif hodograph.visible and hodograph.get_rect().end.y > bottom - VWP_MIN.y:
			vwp_right = hodograph.position.x - GAP
		vw = minf(vw, vwp_right - MARGIN)
		var vh := clampf(vw * VWP_ASPECT, VWP_MIN.y, VWP_MAX.y)
		vh = minf(vh, bottom - info_bottom - GAP)
		vwp.position = Vector2(MARGIN, bottom - vh)
		vwp.size = Vector2(maxf(vw, 0.0), maxf(vh, 0.0))
		hint_bottom = vwp.position.y - GAP

	# Key hint: bottom left (above the VWP), wrapped to the room left of whatever reaches
	# down to it.
	var hint_right := right
	var hint_top := hint_bottom - _hint_height(right - MARGIN)
	for c: Control in [_top_box, hodograph, section]:
		if c.visible and c.get_rect().end.y > hint_top:
			hint_right = minf(hint_right, c.position.x - GAP)
	var hint_w := maxf(hint_right - MARGIN, 0.0)
	hint.offset_left = MARGIN
	hint.offset_right = MARGIN + hint_w
	hint.offset_bottom = -(view.y - hint_bottom)
	hint.offset_top = hint.offset_bottom
	hint.visible = (
		hint_w >= HINT_MIN_WIDTH and hint_bottom - _hint_height(hint_w) > info_bottom + GAP
	)

	fetch_panel.custom_minimum_size.x = minf(480.0, view.x - 2 * MARGIN)


## Height of the key hint wrapped to `width` (measured with the font: a hidden Label does not
## re-wrap, so its minimum size would be stale).
func _hint_height(width: float) -> float:
	var font := hint.get_theme_font("font")
	var font_size := hint.get_theme_font_size("font_size")
	var flags := TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND
	var sz := font.get_multiline_string_size(
		hint.text, HORIZONTAL_ALIGNMENT_LEFT, width, font_size, -1, flags
	)
	return sz.y


## Width of a flow row laid out on one line.
func _natural_width(row: HFlowContainer) -> float:
	var sep := row.get_theme_constant("h_separation")
	var w := 0.0
	for c: Control in row.get_children():
		if c.visible:
			w += c.get_combined_minimum_size().x + sep
	return maxf(w - sep, 0.0)


func set_section(on: bool, shown: bool) -> void:
	section_button.set_pressed_no_signal(on)
	if section.visible != shown:
		section.visible = shown
		_queue_layout()


func set_info(text: String) -> void:
	info.text = text


## Items in `text` are separated by runs of spaces; single spaces inside an item become
## no-break spaces so wrapping only happens between items.
func set_hint(text: String) -> void:
	var re := RegEx.create_from_string("(?<=\\S) (?=\\S)")
	text = re.sub(text, "\u00a0", true)
	if hint.text != text:
		hint.text = text
		_queue_layout()


func set_sites(sites: Array[String], current: String) -> void:
	_sites = sites.duplicate()
	site_option.clear()
	for s in _sites:
		site_option.add_item(s)
	site_option.select(_sites.find(current))
	site_option.disabled = _sites.size() < 2


func set_mosaic(on: bool, available: bool) -> void:
	mosaic_button.set_pressed_no_signal(on)
	mosaic_button.disabled = not available and not on


func set_srm(
	available: bool, on: bool, auto: bool, auto_available: bool, from_deg: float, speed_ms: float
) -> void:
	srm_row.visible = available
	srm_button.set_pressed_no_signal(on)
	srm_auto_button.set_pressed_no_signal(auto)
	srm_auto_button.disabled = not auto_available and not auto
	srm_dir_label.text = " from %03d° " % (roundi(from_deg) % 360)
	srm_speed_label.text = " %d m/s (%d kt) " % [roundi(speed_ms), roundi(speed_ms * 1.94384)]


func set_winds_shown(on: bool) -> void:
	winds_button.set_pressed_no_signal(on)
	if hodograph.visible != on:
		hodograph.visible = on
		_queue_layout()


func set_vwp_shown(on: bool) -> void:
	vwp_button.set_pressed_no_signal(on)
	if vwp.visible != on:
		vwp.visible = on
		_queue_layout()


## Shows `text` next to the mouse at `at` (HUD coordinates), kept inside the canvas;
## empty text hides it.
func set_readout(text: String, at: Vector2) -> void:
	readout.visible = not text.is_empty()
	if not readout.visible:
		return
	if readout_label.text != text:
		readout_label.text = text
		readout.reset_size()
	var sz := readout.get_combined_minimum_size()
	var p := at + READOUT_OFFSET
	if p.x + sz.x > size.x - 4:
		p.x = at.x - READOUT_OFFSET.x - sz.x
	if p.y + sz.y > size.y - 4:
		p.y = at.y - READOUT_OFFSET.y - sz.y
	readout.position = p.max(Vector2(4, 4))


func set_view_3d(on: bool) -> void:
	view_button.text = "2D" if on else "3D"


func set_field(field_name: String, available: Array, storm_relative := false) -> void:
	for n in field_buttons:
		var b: Button = field_buttons[n]
		b.set_pressed_no_signal(n == field_name)
		b.modulate = Color.WHITE if available.has(n) else Color(1, 1, 1, 0.4)
	var rng := Colormaps.range_of(field_name)
	legend_tex.texture = Colormaps.texture_for(field_name)
	legend_lo.text = str(rng[0])
	legend_hi.text = str(rng[1])
	legend_unit.text = Colormaps.unit_of(field_name)
	if storm_relative:
		legend_unit.text = "storm-rel. " + legend_unit.text


## `frame` and `count` describe the position within the current sequence.
func set_playback(
	playing: bool, live: bool, frame: int, count: int, time_text: String, fps: float
) -> void:
	play_button.text = "Pause" if playing else "Play"
	live_button.set_pressed_no_signal(live)
	_setting_slider = true
	slider.max_value = maxi(count - 1, 0)
	slider.value = frame
	slider.editable = count > 1
	_setting_slider = false
	time_label.text = "%s   %d/%d" % [time_text, frame + 1, count]
	var si := SPEEDS.find(fps)
	if si >= 0 and speed_option.selected != si:
		speed_option.select(si)


func _on_slider(v: float) -> void:
	if not _setting_slider:
		scrubbed.emit(int(v))


func _label(font_size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	l.add_theme_constant_override("shadow_offset_x", 1)
	l.add_theme_constant_override("shadow_offset_y", 1)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	return b


## A right-aligned row that wraps when the top-right column is narrow.
func _flow(parent: Control) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.alignment = FlowContainer.ALIGNMENT_END
	f.last_wrap_alignment = FlowContainer.LAST_WRAP_ALIGNMENT_END
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(f)
	_top_rows.append(f)
	return f


func _hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h
