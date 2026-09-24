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
