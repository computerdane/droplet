class_name PpiView
extends Node2D
## 2D plan view: one sweep drawn by ppi.gdshader on a quad centred on the radar, with
## range rings on top. World units are km, +x east, -y north. Wheel zooms, drag pans.

signal view_changed

const ZOOM_STEP := 1.15
const ZOOM_MIN := 0.25
const ZOOM_MAX := 400.0
const DEFAULT_ZOOM := 1.6
const RING_STEP_KM := 50.0
const RING_MAX_KM := 450.0
const RING_COLOR := Color(1, 1, 1, 0.18)

var _dragging := false

@onready var ppi: ColorRect = $PPI
@onready var cam: Camera2D = $Camera
@onready var overlay: Node2D = $Overlay


func _ready() -> void:
	overlay.draw.connect(_draw_overlay)
	reset_camera()


func set_active(on: bool) -> void:
	visible = on
	cam.enabled = on
	if on:
		cam.make_current()


func reset_camera() -> void:
	cam.position = Vector2.ZERO
	cam.zoom = Vector2(DEFAULT_ZOOM, DEFAULT_ZOOM)
	view_changed.emit()


func zoom() -> float:
	return cam.zoom.x


func set_zoom(z: float) -> void:
	z = clampf(z, ZOOM_MIN, ZOOM_MAX)
	cam.zoom = Vector2(z, z)


## Show sweep `i` of `vol` for `field_name`; pass i < 0 to blank the display.
func show_sweep(vol: RadarVolume, i: int, field_name: String) -> void:
	if vol == null or i < 0:
		ppi.visible = false
		return
	var f: Dictionary = vol.sweep(i)["fields"][field_name]
	var mat := ppi.material as ShaderMaterial
	mat.set_shader_parameter("sweep", vol.get_texture(i, field_name))
	mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
	var rng := Colormaps.range_of(field_name)
	mat.set_shader_parameter("cmap_min", rng[0])
	mat.set_shader_parameter("cmap_max", rng[1])
	mat.set_shader_parameter("first_gate_km", float(f["first_gate_m"]) / 1000.0)
	mat.set_shader_parameter("gate_spacing_km", float(f["gate_spacing_m"]) / 1000.0)
	mat.set_shader_parameter("n_gates", int(f["n_gates"]))
	mat.set_shader_parameter("half_size", ppi.size.x / 2.0)
	ppi.visible = true


func _draw_overlay() -> void:
	var r := RING_STEP_KM
	while r <= RING_MAX_KM:
		overlay.draw_arc(Vector2.ZERO, r, 0.0, TAU, 256, RING_COLOR, -1.0)
		r += RING_STEP_KM
	var s := 4.0 / cam.zoom.x  # ~4 px cross at the radar
	overlay.draw_line(Vector2(-s, 0), Vector2(s, 0), Color.WHITE, -1.0)
	overlay.draw_line(Vector2(0, -s), Vector2(0, s), Color.WHITE, -1.0)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		match e.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if e.pressed:
					_zoom_at(e.position, ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if e.pressed:
					_zoom_at(e.position, 1.0 / ZOOM_STEP)
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = e.pressed
	elif event is InputEventMouseMotion and _dragging:
		cam.position -= (event as InputEventMouseMotion).relative / cam.zoom
		view_changed.emit()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# Keep the world point under the cursor fixed.
	var off := screen_pos - get_viewport_rect().size / 2.0
	var before := off / cam.zoom.x
	set_zoom(cam.zoom.x * factor)
	cam.position += before - off / cam.zoom.x
	overlay.queue_redraw()
	view_changed.emit()
