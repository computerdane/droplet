extends Node2D
## Main scene: browse volumes (history), follow the newest one (live), pick sweep and field.
##
## Keys: Up/Down sweep, Left/Right volume, L toggle live, 1-7 field, wheel zoom, drag pan.

const LIVE_RESCAN_SEC := 3.0
const ZOOM_STEP := 1.15
const ZOOM_MIN := 0.25
const ZOOM_MAX := 400.0
const FIELD_KEYS := {
	KEY_1: "REF", KEY_2: "VEL", KEY_3: "SW", KEY_4: "ZDR", KEY_5: "PHI", KEY_6: "RHO", KEY_7: "CFP"
}

var library := RadarLibrary.new()
var volume: RadarVolume
var volume_index := -1
var sweep_index := 0
var field_name := "REF"
var live := true
var _dragging := false

@onready var ppi: ColorRect = $PPI
@onready var cam: Camera2D = $Camera
@onready var hud: Label = $HUD/Label
@onready var live_timer: Timer = $LiveTimer


func _ready() -> void:
	live_timer.wait_time = LIVE_RESCAN_SEC
	live_timer.timeout.connect(_on_live_tick)
	_load_volume(library.volumes.size() - 1)
	_set_live(live)


func _set_live(on: bool) -> void:
	live = on
	if on:
		live_timer.start()
		_on_live_tick()
	else:
		live_timer.stop()
	_update_hud()


func _on_live_tick() -> void:
	library.scan()
	var newest := library.volumes.size() - 1
	if newest < 0:
		return
	var same_dir := volume != null and library.volumes[newest] == volume.path
	if same_dir and volume.is_complete():
		return
	_load_volume(newest)  # new volume, or the current partial one grew


func _load_volume(i: int) -> void:
	if i < 0 or i >= library.volumes.size():
		volume = null
		volume_index = -1
		_update_hud()
		return
	volume = RadarVolume.load_from_dir(library.volumes[i])
	volume_index = i
	if volume != null:
		sweep_index = clampi(sweep_index, 0, volume.sweep_count() - 1)
	_show()


func _show() -> void:
	if volume == null or volume.sweep_count() == 0:
		ppi.visible = false
		_update_hud()
		return
	var i := sweep_index
	if not volume.has_field(i, field_name):
		i = volume.nearest_sweep_with(i, field_name)
		if i < 0:
			ppi.visible = false
			_update_hud()
			return
	var sw := volume.sweep(i)
	var f: Dictionary = sw["fields"][field_name]
	var mat := ppi.material as ShaderMaterial
	mat.set_shader_parameter("sweep", volume.get_texture(i, field_name))
	mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
	var rng := Colormaps.range_of(field_name)
	mat.set_shader_parameter("cmap_min", rng[0])
	mat.set_shader_parameter("cmap_max", rng[1])
	mat.set_shader_parameter("first_gate_km", float(f["first_gate_m"]) / 1000.0)
	mat.set_shader_parameter("gate_spacing_km", float(f["gate_spacing_m"]) / 1000.0)
	mat.set_shader_parameter("n_gates", int(f["n_gates"]))
	mat.set_shader_parameter("half_size", ppi.size.x / 2.0)
	ppi.visible = true
	_update_hud()


func _update_hud() -> void:
	if volume == null:
		hud.text = (
			"No volumes in %s\nRun:  python -m nexrad update KTLX   (or: python -m nexrad live KTLX)"
			% library.root
		)
		return
	var i := sweep_index
	var shown := i if volume.has_field(i, field_name) else volume.nearest_sweep_with(i, field_name)
	var sw := volume.sweep(shown) if shown >= 0 else {}
	var lines := PackedStringArray()
	lines.append(
		(
			"%s  %s  VCP %s%s"
			% [
				volume.icao(),
				volume.time_utc().replace("T", " ").left(19) + "Z",
				str(int(volume.meta.get("vcp", 0))),
				"" if volume.is_complete() else "  (partial)"
			]
		)
	)
	lines.append(
		(
			"volume %d/%d   %s"
			% [volume_index + 1, library.volumes.size(), "LIVE" if live else "history"]
		)
	)
	if not sw.is_empty():
		lines.append(
			(
				"sweep %d/%d  elev %.2f°  %s  [%s]"
				% [
					shown + 1,
					volume.sweep_count(),
					float(sw["elevation_deg"]),
					field_name,
					" ".join(volume.fields_of(shown))
				]
			)
		)
	lines.append("zoom %.2f px/km" % cam.zoom.x)
	hud.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event as InputEventKey)
	elif event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion and _dragging:
		cam.position -= (event as InputEventMouseMotion).relative / cam.zoom


func _handle_key(e: InputEventKey) -> void:
	match e.keycode:
		KEY_UP:
			if volume:
				sweep_index = mini(sweep_index + 1, volume.sweep_count() - 1)
				_show()
		KEY_DOWN:
			sweep_index = maxi(sweep_index - 1, 0)
			_show()
		KEY_LEFT:
			if volume_index > 0:
				_set_live(false)
				_load_volume(volume_index - 1)
		KEY_RIGHT:
			if volume_index < library.volumes.size() - 1:
				_load_volume(volume_index + 1)
		KEY_L:
			_set_live(not live)
		KEY_HOME:
			cam.position = Vector2.ZERO
			cam.zoom = Vector2(2, 2)
			_update_hud()
		_:
			if FIELD_KEYS.has(e.keycode):
				field_name = FIELD_KEYS[e.keycode]
				_show()


func _handle_mouse_button(e: InputEventMouseButton) -> void:
	match e.button_index:
		MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(e.position, ZOOM_STEP)
		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(e.position, 1.0 / ZOOM_STEP)
		MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE:
			_dragging = e.pressed


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var before := get_global_mouse_position()
	var z := clampf(cam.zoom.x * factor, ZOOM_MIN, ZOOM_MAX)
	cam.zoom = Vector2(z, z)
	# Keep the point under the cursor fixed.
	var after := cam.get_global_transform_with_canvas().affine_inverse() * screen_pos
	cam.position += before - after
	_update_hud()
