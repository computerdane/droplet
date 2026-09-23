class_name Warnings
extends Node
## NWS storm-based warnings (tornado, severe thunderstorm, flash flood, special marine) from
## the Iowa Environmental Mesonet's archive, which answers any time window back to 2002 and
## keeps up with live issuance, with CORS open to browsers. Warnings are fetched an hour at a
## time (every warning whose polygon overlaps that hour) and cached; the hour containing "now"
## is refetched every LIVE_REFRESH_SEC. `changed` fires when a fetch lands. The archive only
## has each warning's first polygon (not the updates that shrink it), so that polygon stays
## up until the warning expires.

signal changed

const URL := "https://mesonet.agron.iastate.edu/geojson/sbw.geojson?sts=%s&ets=%s"
const BUCKET_SEC := 3600
const LIVE_REFRESH_SEC := 60
const RETRY_SEC := 120
## Phenomena drawn, most important last (drawn on top): name and colour.
const KINDS := {
	"MA": ["Special Marine Warning", Color("ff9f40")],
	"FF": ["Flash Flood Warning", Color("35e06f")],
	"SV": ["Severe Thunderstorm Warning", Color("ffd000")],
	"TO": ["Tornado Warning", Color("ff2d2d")],
}

var enabled := true
var _buckets: Dictionary = {}  # bucket start (unix) -> {fetched: unix, warnings: Array}
var _requests: Dictionary = {}  # bucket start -> HTTPRequest in flight


## True while a fetch is in flight (LoopExport waits for it so frames carry their warnings).
func busy() -> bool:
	return not _requests.is_empty()


## Warnings in effect at unix time `t`, drawing order (see KINDS):
## [{kind, name, color, begin, end, wfo, event, rings: Array[PackedVector2Array] (lon, lat)}].
## Starts fetching the hour around `t` if it is not cached (or stale); `changed` follows.
func active_at(t: int) -> Array:
	if not enabled or t <= 0:
		return []
	var start := t - posmod(t, BUCKET_SEC)
	_ensure(start)
	var out := []
	var entry: Dictionary = _buckets.get(start, {})
	for w in entry.get("warnings", []):
		if w["begin"] <= t and t < w["end"]:
			out.append(w)
	out.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return KINDS.keys().find(a["kind"]) < KINDS.keys().find(b["kind"])
	)
	return out


func _ensure(start: int) -> void:
	if _requests.has(start):
		return
	var now := int(Time.get_unix_time_from_system())
	var entry: Dictionary = _buckets.get(start, {})
	if not entry.is_empty():
		var age := now - int(entry["fetched"])
		var live := start + BUCKET_SEC > now - LIVE_REFRESH_SEC
		var failed: bool = entry.get("failed", false)
		if not (live and age >= LIVE_REFRESH_SEC) and not (failed and age >= RETRY_SEC):
			return
	var req := HTTPRequest.new()
	req.timeout = 30.0
	add_child(req)
	_requests[start] = req
	req.request_completed.connect(_on_fetched.bind(start, req))
	var iso := func(u: int) -> String: return Time.get_datetime_string_from_unix_time(u) + "Z"
	var err := req.request(URL % [iso.call(start), iso.call(start + BUCKET_SEC)])
	if err != OK:
		_on_fetched(
			HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), start, req
		)


func _on_fetched(
	result: int,
	code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	start: int,
	req: HTTPRequest
) -> void:
	_requests.erase(start)
	req.queue_free()
	var now := int(Time.get_unix_time_from_system())
	var old: Dictionary = _buckets.get(start, {})
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("warnings: fetch failed (result %d, HTTP %d)" % [result, code])
		_buckets[start] = {"fetched": now, "failed": true, "warnings": old.get("warnings", [])}
		return
	_buckets[start] = {"fetched": now, "warnings": parse(body.get_string_from_utf8())}
	changed.emit()


## The warnings of an IEM sbw.geojson FeatureCollection, KINDS only.
static func parse(text: String) -> Array:
	var json := JSON.new()
	var out := []
	if json.parse(text) != OK or not json.data is Dictionary:
		return out
	var data: Dictionary = json.data
	for f in data.get("features", []):
		var p: Dictionary = f.get("properties", {})
		var kind: String = str(p.get("phenomena", ""))
		if not KINDS.has(kind) or p.get("significance") != "W":
			continue
		var rings: Array[PackedVector2Array] = []
		var geom: Dictionary = f.get("geometry", {})
		var polys: Array = geom.get("coordinates", [])
		if geom.get("type") == "Polygon":
			polys = [polys]
		for poly in polys:
			if poly.is_empty():
				continue
			var ring := PackedVector2Array()
			for c in poly[0]:  # outer ring
				ring.append(Vector2(float(c[0]), float(c[1])))
			rings.append(ring)
		(
			out
			. append(
				{
					"kind": kind,
					"name": KINDS[kind][0],
					"color": KINDS[kind][1],
					"begin": _unix(p.get("polygon_begin", p.get("issue", ""))),
					"end": maxi(_unix(p.get("polygon_end", "")), _unix(p.get("expire", ""))),
					"wfo": str(p.get("wfo", "")),
					"event": int(p.get("eventid", 0)),
					"emergency": bool(p.get("is_emergency", false)),
					"pds": bool(p.get("is_pds", false)),
					"rings": rings,
				}
			)
		)
	return out


static func _unix(iso) -> int:
	if not iso is String or iso.is_empty():
		return 0
	return Time.get_unix_time_from_datetime_string(iso.trim_suffix("Z"))


## "Tornado Warning OUN 26 until 20:45Z" (with EMERGENCY / PDS when flagged).
static func describe(w: Dictionary) -> String:
	var tag := ""
	if w["emergency"]:
		tag = " EMERGENCY"
	elif w["pds"]:
		tag = " PDS"
	var until := Time.get_datetime_string_from_unix_time(w["end"]).substr(11, 5)
	return "%s%s  %s %d until %sZ" % [w["name"], tag, w["wfo"], w["event"], until]


## Warnings among `warnings` whose polygon contains the point `lonlat`.
static func containing(warnings: Array, lonlat: Vector2) -> Array:
	var out := []
	for w in warnings:
		for ring in w["rings"]:
			if Geometry2D.is_point_in_polygon(lonlat, ring):
				out.append(w)
				break
	return out


## `warnings` for drawing around a site: [{color, rings: Array[PackedVector2Array]}] in the 2D
## view's frame (km, +x east, +y south).
static func project(warnings: Array, site_lat: float, site_lon: float) -> Array:
	var out := []
	for w in warnings:
		var rings: Array[PackedVector2Array] = []
		for ring in w["rings"]:
			var pts := PackedVector2Array()
			for ll in ring:
				var p := Basemap.project(ll.y, ll.x, site_lat, site_lon)
				pts.append(Vector2(p.x, -p.y))
			rings.append(pts)
		out.append({"color": w["color"], "rings": rings})
	return out


## "1 tornado, 3 severe thunderstorm" for the info text.
static func summary(warnings: Array) -> String:
	var counts := {}
	for w in warnings:
		counts[w["kind"]] = counts.get(w["kind"], 0) + 1
	var parts := PackedStringArray()
	var order: Array = KINDS.keys()
	order.reverse()  # most important first
	for kind in order:
		if counts.has(kind):
			var what: String = KINDS[kind][0].trim_suffix(" Warning").to_lower()
			parts.append("%d %s" % [counts[kind], what])
	return ", ".join(parts)
