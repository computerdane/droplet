extends "res://tests/test_case.gd"
## Two-finger gestures (TouchGestures) from synthetic touch events.


func _touch(index: int, pos: Vector2, pressed: bool) -> InputEventScreenTouch:
	var e := InputEventScreenTouch.new()
	e.index = index
	e.position = pos
	e.pressed = pressed
	return e


func _drag(index: int, pos: Vector2) -> InputEventScreenDrag:
	var e := InputEventScreenDrag.new()
	e.index = index
	e.position = pos
	return e


func test_pinch_and_pan() -> void:
	var g := TouchGestures.new()
	check(g.feed(_touch(0, Vector2(100, 100), true)).is_empty(), "one finger down")
	check(g.feed(_drag(0, Vector2(110, 100))).is_empty(), "one finger drags: left to the mouse")
	check(not g.active(), "one finger is not a gesture")
	g.feed(_touch(1, Vector2(210, 100), true))
	check(g.active(), "two fingers")
	var step := g.feed(_drag(1, Vector2(310, 100)))  # apart: 100 px -> 200 px
	check_eq(step["zoom"], 2.0, "spread doubles")
	check_eq(step["pan"], Vector2(50, 0), "centroid moves half the finger's motion")
	check_eq(step["center"], Vector2(210, 100), "centroid")
	step = g.feed(_drag(0, Vector2(210, 150)))  # both now 100 px apart, moved
	check(is_equal_approx(step["zoom"], Vector2(100, 50).length() / 200.0), "pinch in")
	g.feed(_touch(1, Vector2(310, 100), false))
	check(not g.active(), "lifting one ends the gesture")
	check(g.feed(_drag(0, Vector2(220, 150))).is_empty(), "back to one finger")
