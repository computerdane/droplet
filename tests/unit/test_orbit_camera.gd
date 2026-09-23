extends "res://tests/test_case.gd"
## Mouse drags must change the active 3D camera in the direction of the gesture.


class InputCamera:
	extends OrbitCamera

	# The test runner calls methods during SceneTree initialization, before root enters the tree.
	func _apply() -> void:
		pass


func _button(index: MouseButton, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	return event


func _motion(relative: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.relative = relative
	return event


func test_left_drag_rotates_with_map() -> void:
	var camera := InputCamera.new()
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(camera)
	camera.current = true
	camera._unhandled_input(_button(MOUSE_BUTTON_LEFT, true))
	camera._unhandled_input(_motion(Vector2(40, 20)))
	check_eq(camera.yaw, 12.0, "drag right increases yaw")
	check_eq(camera.pitch, 38.0, "drag down keeps the original pitch direction")
	check_eq(camera.target, Vector3.ZERO, "rotation keeps the target fixed")
	camera._unhandled_input(_button(MOUSE_BUTTON_LEFT, false))
	camera._unhandled_input(_motion(Vector2(40, 20)))
	check_eq(camera.yaw, 12.0, "released left button stops rotation")
	check_eq(camera.pitch, 38.0, "released left button stops pitch change")
	camera._unhandled_input(_button(MOUSE_BUTTON_RIGHT, true))
	camera._unhandled_input(_motion(Vector2(40, 20)))
	check_eq(camera.yaw, 12.0, "right drag keeps yaw")
	check_eq(camera.pitch, 38.0, "right drag keeps pitch")
	check(camera.target.x < 0.0, "right drag still pans west")
	check(camera.target.z < 0.0, "right drag pans north after the horizontal orbit")
	camera.queue_free()
