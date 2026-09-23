class_name TouchGestures
extends RefCounted
## Two-finger gestures from raw touch events, for the 2D view and the orbit camera. One finger
## needs nothing here: Godot turns the first touch into left-button mouse events. While two or
## more fingers are down `active()` is true and callers ignore that emulated mouse, so the
## first finger does not also drag. feed() returns the step since the last event:
## {zoom: pinch factor (> 1 = fingers apart), pan: centroid motion in pixels, center: centroid},
## or {} when there is no two-finger step.

var _points: Dictionary = {}  # touch index -> position


func active() -> bool:
	return _points.size() >= 2


func feed(event: InputEvent) -> Dictionary:
	if event is InputEventScreenTouch:
		var t := event as InputEventScreenTouch
		if t.pressed:
			_points[t.index] = t.position
		else:
			_points.erase(t.index)
		return {}
	if not event is InputEventScreenDrag:
		return {}
	var d := event as InputEventScreenDrag
	if not _points.has(d.index) or _points.size() < 2:
		_points[d.index] = d.position
		return {}
	var keys := _points.keys()
	keys.sort()
	var a: int = keys[0]
	var b: int = keys[1]
	if d.index != a and d.index != b:
		_points[d.index] = d.position
		return {}
	var before_a: Vector2 = _points[a]
	var before_b: Vector2 = _points[b]
	_points[d.index] = d.position
	var after_a: Vector2 = _points[a]
	var after_b: Vector2 = _points[b]
	var span_before := before_a.distance_to(before_b)
	var span_after := after_a.distance_to(after_b)
	var center := (after_a + after_b) / 2.0
	return {
		"zoom": span_after / span_before if span_before > 1.0 else 1.0,
		"pan": center - (before_a + before_b) / 2.0,
		"center": center,
	}
