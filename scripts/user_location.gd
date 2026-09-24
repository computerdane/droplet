class_name UserLocation
extends Node
## The viewer's own position, shown on the map when they turn it on (G / the Location button;
## off by default). Web only for now: the browser Geolocation API, asked once per turn-on, so
## the permission prompt appears only then. The desktop build says location comes later. The
## position stays in memory: it is never stored, logged or sent anywhere.

## The position arrived or the toggle changed.
signal changed

## JS global that the geolocation request calls back (distinct from basemap's).
const JS_CALLBACK := "droplet_location_done"
## Error codes from the request: GeolocationPositionError's 1-3, and ours for no API at all.
const ERR_INSECURE := -1
const MESSAGES := {
	ERR_INSECURE: "Location needs a secure (https) page",
	1: "Location permission denied",
	2: "Location unavailable",
	3: "Location request timed out",
}
const DESKTOP_MESSAGE := "Your location is available in the browser version; desktop comes later"
const TIP_WEB := "Show your location on the map (G). The browser asks first."
const TIP_DESKTOP := "Your location: available in the browser version for now (G)"

var enabled := false
var latlon := Vector2.INF  # (lat, lon) degrees; INF until the browser answers
var accuracy_m := 0.0  # the browser's estimate (m); 0 unknown
var _requesting := false
var _js_done: JavaScriptObject  # kept alive while a request may call back
var _hud: Hud


static func available() -> bool:
	return OS.has_feature("web")


func setup(hud: Hud) -> void:
	_hud = hud
	hud.location_toggled.connect(request_toggle)
	_sync_hud()


## Whether the marker is to be drawn.
func shown() -> bool:
	return enabled and latlon != Vector2.INF


## Turns off, or (web) asks the browser for the position and turns on when it answers.
func request_toggle() -> void:
	if enabled:
		enabled = false
		_sync_hud()
		changed.emit()
		return
	if not available():
		_notify(DESKTOP_MESSAGE)
		_sync_hud()
		return
	_sync_hud()  # the button stays up until the browser answers
	if _requesting:
		return
	_requesting = true
	var window := JavaScriptBridge.get_interface("window")
	_js_done = JavaScriptBridge.create_callback(_on_js_done)
	window.droplet_location_done = _js_done  # JS_CALLBACK
	(
		JavaScriptBridge
		. eval(
			(
				"""
			(() => {
				const done = self.%s;
				if (!self.isSecureContext || !('geolocation' in navigator)) {
					done(%d, 0, 0, 0);
					return;
				}
				navigator.geolocation.getCurrentPosition(
					(p) => done(0, p.coords.latitude, p.coords.longitude, p.coords.accuracy),
					(e) => done(e.code || 2, 0, 0, 0),
					{enableHighAccuracy: false, timeout: 15000, maximumAge: 60000});
			})()
			"""
				% [JS_CALLBACK, ERR_INSECURE]
			),
			true
		)
	)


func _on_js_done(args: Array) -> void:
	_requesting = false
	var code := int(args[0]) if args.size() > 0 else 2
	if code != 0 or args.size() < 4:
		var text: String = MESSAGES.get(code, MESSAGES[2])
		print("location: ", text)  # the outcome only, never the position (web/smoke.mjs waits on it)
		_notify(text)
		_sync_hud()
		return
	print("location: shown")
	_notify("Showing your location")
	set_position(Vector2(float(args[1]), float(args[2])), float(args[3]))


## Shows the marker at `ll` (lat, lon): the browser's answer, or a test's.
func set_position(ll: Vector2, accuracy := 0.0) -> void:
	accuracy_m = accuracy
	latlon = ll
	enabled = true
	_sync_hud()
	changed.emit()


func _notify(text: String) -> void:
	if _hud != null:
		_hud.notify(text)


func _sync_hud() -> void:
	if _hud != null:
		_hud.set_location(enabled, available(), TIP_WEB if available() else TIP_DESKTOP)


## Distance (km) and bearing (degrees clockwise from north) of `ll` from `center`, both (lat, lon).
static func range_bearing(ll: Vector2, center: Vector2) -> Vector2:
	var p := Basemap.project(ll.x, ll.y, center.x, center.y)  # +x east, +y north
	return Vector2(p.length(), fposmod(rad_to_deg(atan2(p.x, p.y)), 360.0))


## `ll` in the 2D / 3D world frame around `center`: km, +x east, +y south.
static func world_of(ll: Vector2, center: Vector2) -> Vector2:
	var p := Basemap.project(ll.x, ll.y, center.x, center.y)
	return Vector2(p.x, -p.y)


## "your location: 23.4 km @ 215° from KTLX" for the info text.
static func describe(ll: Vector2, center: Vector2, site: String) -> String:
	var rb := range_bearing(ll, center)
	return "your location: %.1f km @ %03d° from %s" % [rb.x, roundi(rb.y) % 360, site]
