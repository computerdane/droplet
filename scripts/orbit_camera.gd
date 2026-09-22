class_name OrbitCamera
extends Camera3D
## Orbits a target point on the ground. Left drag rotates, right/middle drag pans along the
## ground, wheel zooms. Yaw 0 looks north; pitch is the angle above the horizon.

signal moved

const ROTATE_SPEED := 0.3  # degrees per pixel
const PAN_SPEED := 0.0015  # fraction of distance per pixel
const ZOOM_STEP := 1.12
const DIST_MIN := 5.0
const DIST_MAX := 3000.0
const PITCH_MIN := -5.0
const PITCH_MAX := 89.0
const DEFAULT_YAW := 0.0
const DEFAULT_PITCH := 32.0
const DEFAULT_DIST := 520.0

var target := Vector3.ZERO
var yaw := DEFAULT_YAW
var pitch := DEFAULT_PITCH
var distance := DEFAULT_DIST
var _rotating := false
var _panning := false


func _ready() -> void:
	near = 0.05
	far = 10000.0
	_apply()


func reset() -> void:
	target = Vector3.ZERO
	yaw = DEFAULT_YAW
	pitch = DEFAULT_PITCH
	distance = DEFAULT_DIST
	_apply()


func set_view(p_yaw: float, p_pitch: float, p_distance: float) -> void:
	yaw = p_yaw
	pitch = clampf(p_pitch, PITCH_MIN, PITCH_MAX)
	distance = clampf(p_distance, DIST_MIN, DIST_MAX)
	_apply()


func _apply() -> void:
	var p := deg_to_rad(pitch)
	var y := deg_to_rad(yaw)
	# Camera sits "behind" the target: yaw 0 means it is south of the target, looking north.
	var offset := Vector3(-sin(y) * cos(p), sin(p), cos(y) * cos(p)) * distance
	position = target + offset
	look_at(target, Vector3.UP)
	moved.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not current or not is_visible_in_tree():
		return
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		match e.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if e.pressed:
					distance = maxf(distance / ZOOM_STEP, DIST_MIN)
					_apply()
			MOUSE_BUTTON_WHEEL_DOWN:
				if e.pressed:
					distance = minf(distance * ZOOM_STEP, DIST_MAX)
					_apply()
			MOUSE_BUTTON_LEFT:
				_rotating = e.pressed
			MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				_panning = e.pressed
	elif event is InputEventMouseMotion:
		var rel := (event as InputEventMouseMotion).relative
		if _rotating:
			yaw -= rel.x * ROTATE_SPEED
			pitch = clampf(pitch + rel.y * ROTATE_SPEED, PITCH_MIN, PITCH_MAX)
			_apply()
		elif _panning:
			var y := deg_to_rad(yaw)
			var right := Vector3(cos(y), 0, sin(y))
			var forward := Vector3(sin(y), 0, -cos(y))
			target += (-right * rel.x + forward * rel.y) * distance * PAN_SPEED
			_apply()
