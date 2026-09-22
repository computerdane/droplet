class_name FetchPanel
extends PanelContainer
## Dialog for fetching radar data from the UI (F): a site, and either its newest volume,
## the volume at a time, every volume in a time range, or live following. main.gd runs
## the requests through Fetcher and pushes job status back with set_jobs(). The text
## fields are the only focusable controls in the HUD; closing the panel releases focus so
## keyboard shortcuts work again.

signal update_requested(site: String, at: String, from: String, to: String)
signal live_requested(site: String)
signal stop_requested

enum Mode { LATEST, AT, RANGE, LIVE }

const MODE_NAMES := ["Newest volume", "Volume at time", "Time range", "Live"]
const HELP := "Times are UTC, e.g. 2013-05-20T20:00Z. A range fetches every volume in it."

var _site: LineEdit
var _mode: OptionButton
var _t1: LineEdit
var _t2: LineEdit
var _t1_label: Label
var _t2_label: Label
var _jobs: Label


func _ready() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.03, 0.03, 0.06, 0.92)
	style.set_content_margin_all(12)
	style.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", style)
	custom_minimum_size.x = 480
	var box := VBoxContainer.new()
	add_child(box)

	var title := Label.new()
	title.text = "Fetch radar data"
	title.add_theme_font_size_override("font_size", 16)
	box.add_child(title)

	var row1 := HBoxContainer.new()
	box.add_child(row1)
	row1.add_child(_text("Site"))
	_site = _line_edit("KTLX", 70)
	_site.max_length = 4
	_site.text_changed.connect(
		func(t: String) -> void:
			var col := _site.caret_column
			_site.text = t.to_upper()
			_site.caret_column = col
	)
	row1.add_child(_site)
	_mode = OptionButton.new()
	_mode.focus_mode = Control.FOCUS_NONE
	for n in MODE_NAMES:
		_mode.add_item(n)
	_mode.select(Mode.AT)
	_mode.item_selected.connect(func(_i: int) -> void: _update_fields())
	row1.add_child(_mode)

	var row2 := HBoxContainer.new()
	box.add_child(row2)
	_t1_label = _text("At")
	row2.add_child(_t1_label)
	_t1 = _line_edit("", 170)
	row2.add_child(_t1)
	_t2_label = _text("To")
	row2.add_child(_t2_label)
	_t2 = _line_edit("", 170)
	row2.add_child(_t2)

	var row3 := HBoxContainer.new()
	box.add_child(row3)
	var start := _action("Start", "Run the request (Enter)")
	start.pressed.connect(_submit)
	row3.add_child(start)
	var stop := _action("Stop all", "Stop running fetches and live followers")
	stop.pressed.connect(stop_requested.emit)
	row3.add_child(stop)
	var close := _action("Close", "Close (Esc or F)")
	close.pressed.connect(close_panel)
	row3.add_child(close)

	_jobs = _text("")
	_jobs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_jobs.custom_minimum_size.x = 456
	box.add_child(_jobs)
	var help := _text(HELP)
	help.modulate = Color(1, 1, 1, 0.55)
	help.add_theme_font_size_override("font_size", 11)
	box.add_child(help)
	_update_fields()


## Opens the panel with `site` and times around `unix_time` (the frame on screen) filled in.
func open_panel(site: String, unix_time: int) -> void:
	if not site.is_empty():
		_site.text = site
	if unix_time > 0:
		_t1.text = _iso(unix_time)
		_t2.text = _iso(unix_time + 30 * 60)
		if _mode.selected == Mode.RANGE:
			_t1.text = _iso(unix_time - 30 * 60)
	visible = true
	_site.grab_focus()


func close_panel() -> void:
	visible = false
	get_viewport().gui_release_focus()


func set_jobs(lines: PackedStringArray) -> void:
	_jobs.text = "\n".join(lines)


## Greys out the Live mode, with `why` as its tooltip (web pages without cross-origin isolation).
func disable_live(why: String) -> void:
	_mode.set_item_disabled(Mode.LIVE, true)
	_mode.set_item_tooltip(Mode.LIVE, why)


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close_panel()
		get_viewport().set_input_as_handled()


func _submit() -> void:
	var site := _site.text.strip_edges().to_upper()
	if site.length() != 4:
		set_jobs(PackedStringArray(["Site must be a 4-letter ICAO id, e.g. KTLX"]))
		return
	match _mode.selected:
		Mode.LATEST:
			update_requested.emit(site, "", "", "")
		Mode.AT:
			update_requested.emit(site, _t1.text.strip_edges(), "", "")
		Mode.RANGE:
			update_requested.emit(site, "", _t1.text.strip_edges(), _t2.text.strip_edges())
		Mode.LIVE:
			live_requested.emit(site)
	get_viewport().gui_release_focus()


func _update_fields() -> void:
	var m := _mode.selected
	_t1.visible = m == Mode.AT or m == Mode.RANGE
	_t1_label.visible = _t1.visible
	_t1_label.text = "From" if m == Mode.RANGE else "At"
	_t2.visible = m == Mode.RANGE
	_t2_label.visible = _t2.visible


static func _iso(unix_time: int) -> String:
	return Time.get_datetime_string_from_unix_time(unix_time).left(16) + "Z"


func _line_edit(text: String, width: float) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size.x = width
	e.text_submitted.connect(func(_t: String) -> void: _submit())
	return e


func _action(text: String, tip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	return b


func _text(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
