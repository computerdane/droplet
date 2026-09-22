class_name Hud
extends Control
## On-screen controls: info text, site picker, 2D/3D toggle, field buttons, colour legend and
## a playback bar. Built in code; emits intent signals and main.gd pushes state back via
## the set_* methods. Nothing here takes keyboard focus, so shortcuts keep working.

signal play_toggled
signal step_requested(delta: int)
signal scrubbed(frame_in_sequence: int)
signal speed_selected(fps: float)
signal live_toggled
signal site_selected(site: String)
signal view_toggled
signal mosaic_toggled
signal field_selected(field_name: String)

const SPEEDS := [1.0, 2.0, 4.0, 8.0, 15.0]
const DEFAULT_SPEED_INDEX := 2
const LEGEND_WIDTH := 280

var info: Label
var hint: Label
var site_option: OptionButton
var view_button: Button
var mosaic_button: Button
var field_buttons: Dictionary = {}  # name -> Button
var legend_tex: TextureRect
var legend_lo: Label
var legend_hi: Label
var legend_unit: Label
var play_button: Button
var slider: HSlider
var time_label: Label
var speed_option: OptionButton
var live_button: Button
var _sites: Array[String] = []
var _setting_slider := false


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_info()
	_build_top_right()
	_build_bottom_bar()


func _build_info() -> void:
	info = _label(14)
	info.position = Vector2(12, 10)
	add_child(info)
	hint = _label(12)
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	hint.offset_left = 12
	hint.offset_top = -52
	hint.offset_bottom = -52
	hint.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(hint)


func _build_top_right() -> void:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.offset_left = -12
	box.offset_right = -12
	box.offset_top = 10
	box.alignment = BoxContainer.ALIGNMENT_END
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(box)

	var row := _hbox()
	row.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(row)
	site_option = OptionButton.new()
	site_option.focus_mode = Control.FOCUS_NONE
	site_option.tooltip_text = "Radar site (sites with decoded volumes)"
	site_option.item_selected.connect(func(i: int) -> void: site_selected.emit(_sites[i]))
	row.add_child(site_option)
	mosaic_button = _button("Mosaic", "Also draw other sites at the same time (M)")
	mosaic_button.toggle_mode = true
	mosaic_button.pressed.connect(mosaic_toggled.emit)
	row.add_child(mosaic_button)
	view_button = _button("3D", "Toggle 2D plan view / 3D volume (V)")
	view_button.pressed.connect(view_toggled.emit)
	row.add_child(view_button)

	var fields := _hbox()
	fields.alignment = BoxContainer.ALIGNMENT_END
	box.add_child(fields)
	var group := ButtonGroup.new()
	for i in RadarVolume.FIELDS.size():
		var fname: String = RadarVolume.FIELDS[i]
		var b := _button(fname, "%s (%d)" % [fname, i + 1])
		b.toggle_mode = true
		b.button_group = group
		b.pressed.connect(func() -> void: field_selected.emit(fname))
		fields.add_child(b)
		field_buttons[fname] = b

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

	var row := _hbox()
	panel.add_child(row)
	var prev := _button("<", "Previous volume (Left)")
	prev.pressed.connect(func() -> void: step_requested.emit(-1))
	row.add_child(prev)
	play_button = _button("Play", "Play / pause the loop (Space)")
	play_button.custom_minimum_size.x = 64
	play_button.pressed.connect(play_toggled.emit)
	row.add_child(play_button)
	var next := _button(">", "Next volume (Right)")
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


func set_info(text: String) -> void:
	info.text = text


func set_hint(text: String) -> void:
	hint.text = text


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


func set_view_3d(on: bool) -> void:
	view_button.text = "2D" if on else "3D"


func set_field(field_name: String, available: Array) -> void:
	for n in field_buttons:
		var b: Button = field_buttons[n]
		b.set_pressed_no_signal(n == field_name)
		b.modulate = Color.WHITE if available.has(n) else Color(1, 1, 1, 0.4)
	var rng := Colormaps.range_of(field_name)
	legend_tex.texture = Colormaps.texture_for(field_name)
	legend_lo.text = str(rng[0])
	legend_hi.text = str(rng[1])
	legend_unit.text = Colormaps.unit_of(field_name)


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


func _hbox() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return h
