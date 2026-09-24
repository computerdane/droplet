extends "res://tests/test_case.gd"
## The viewer's position (UserLocation): projection around a radar, the info line, the toggle
## state. The browser request itself is exercised by web/smoke.mjs.

const KTST := Vector2(35.333, -97.278)  # lat, lon


func test_range_bearing() -> void:
	var north := UserLocation.range_bearing(KTST + Vector2(1, 0), KTST)
	check(absf(north.x - 111.2) < 0.3, "1 deg north is ~111.2 km (%.2f)" % north.x)
	check(absf(north.y) < 0.01 or absf(north.y - 360.0) < 0.01, "due north (%.3f)" % north.y)
	var east := UserLocation.range_bearing(KTST + Vector2(0, 1), KTST)
	check(absf(east.x - 90.7) < 0.5, "1 deg east is ~90.7 km (%.2f)" % east.x)
	check(absf(east.y - 90.0) < 0.5, "about due east (%.2f)" % east.y)
	var sw := UserLocation.range_bearing(KTST + Vector2(-0.2, -0.2), KTST)
	check(sw.y > 200.0 and sw.y < 235.0, "southwest (%.1f)" % sw.y)
	check_eq(UserLocation.range_bearing(KTST, KTST), Vector2.ZERO, "at the radar")


func test_world_frame() -> void:
	var p := UserLocation.world_of(KTST + Vector2(0.5, 0.5), KTST)
	check(p.x > 40.0, "east is +x (%.1f)" % p.x)
	check(p.y < -50.0, "north is -y in the 2D/3D world frame (%.1f)" % p.y)
	var q := Basemap.project(KTST.x + 0.5, KTST.y + 0.5, KTST.x, KTST.y)
	check_eq(p, Vector2(q.x, -q.y), "the same projection as the station markers")


func test_describe() -> void:
	check_eq(
		UserLocation.describe(KTST + Vector2(1, 0), KTST, "KTST"),
		"your location: 111.2 km @ 000° from KTST",
		"info line"
	)


func test_toggle_state() -> void:
	var loc := UserLocation.new()
	check(not loc.enabled, "off by default")
	check(not loc.shown(), "nothing shown before a position")
	var emitted := [0]
	loc.changed.connect(func() -> void: emitted[0] += 1)
	loc.set_position(Vector2(35.2, -97.4))
	check(loc.enabled and loc.shown(), "a position turns it on")
	check_eq(emitted[0], 1, "changed on a position")
	loc.request_toggle()
	check(not loc.enabled and not loc.shown(), "toggle turns it off")
	check_eq(emitted[0], 2, "changed on turning off")
	if not UserLocation.available():
		loc.request_toggle()  # desktop: only a notice (no HUD here), stays off
		check(not loc.enabled, "desktop cannot turn it on")
		check_eq(emitted[0], 2, "no change on desktop")
	loc.free()


## The request state machine without the browser: begin_request() stands in for the turn-on
## that asks it, answer() / expire() for its callback and the GDScript timeout.
func test_pending_requests() -> void:
	var loc := UserLocation.new()
	var emitted := [0]
	loc.changed.connect(func() -> void: emitted[0] += 1)
	var here := Vector2(35.2, -97.4)

	var a := loc.begin_request()
	check(loc.pending() and not loc.shown(), "pending, not shown yet")
	loc.answer(a, 0, here, 50.0)
	check(loc.shown() and not loc.pending(), "an answer turns it on")
	check_eq(loc.accuracy_m, 50.0, "accuracy kept")
	check_eq(emitted[0], 1, "changed on the answer")
	loc.answer(a, 0, here + Vector2(1, 0))
	check_eq(loc.latlon, here, "a second answer to the same request is ignored")
	loc.request_toggle()
	check(not loc.enabled, "off")

	var b := loc.begin_request()
	loc.request_toggle()  # pressed again while pending: cancels
	check(not loc.pending() and not loc.enabled, "a press while pending cancels")
	loc.answer(b, 0, here)
	check(not loc.enabled, "a late answer after cancelling does not turn it on")

	var c := loc.begin_request()
	loc.expire(c)
	check(not loc.pending() and not loc.enabled, "the timeout clears the request")
	loc.answer(c, 0, here)
	check(not loc.enabled, "an answer after the timeout is ignored")

	var d := loc.begin_request()
	var e := loc.begin_request()
	check(e != d, "each request has its own id")
	loc.expire(d)
	check(loc.pending(), "the superseded request's timeout leaves the new one pending")
	loc.answer(d, 0, here)
	check(not loc.enabled and loc.pending(), "the superseded request's answer is ignored")
	loc.answer(e, 1)
	check(not loc.enabled and not loc.pending(), "denied: stays off, nothing pending")
	loc.answer(e, 0, here)
	check(not loc.enabled, "nothing after the denial")
	check_eq(emitted[0], 2, "changed only on turning on and off")
	loc.free()
