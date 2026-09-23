class_name Outlooks
extends Node
## SPC Day 1 convective outlook (categorical risk areas) in effect at a time, from the Iowa
## Environmental Mesonet's archive (api/1/nws/spc_outlook.geojson, CORS open, back to 2002,
## and live). A convective day runs 12Z to 12Z and is named by its first date; its outlooks
## are issued at the CYCLES hours (01Z falls on the next calendar date). The outlook in effect
## at t is the latest cycle issued by then that has categorical areas; each (day, cycle) is
## fetched once and cached (an empty answer for a recent cycle is retried: it may not be out
## yet). `changed` fires when a fetch lands.

signal changed

const URL := (
	"https://mesonet.agron.iastate.edu/api/1/nws/spc_outlook.geojson"
	+ "?day=1&valid=%s&cycle=%d&outlook_type=C"
)
const CYCLES: Array[int] = [6, 13, 16, 20, 1]  # in issuance order within a convective day
const ISSUE_MIN := {6: 0, 13: 0, 16: 30, 20: 0, 1: 0}  # minutes past the cycle hour
const RECENT_SEC := 6 * 3600
const RETRY_SEC := 600
## Categories, lowest risk first: name and colour (SPC's own palette, brightened for a dark map).
const KINDS := {
	"TSTM": ["General thunderstorms", Color("8fd98f")],
	"MRGL": ["Marginal risk", Color("3faa3f")],
	"SLGT": ["Slight risk", Color("f2f25a")],
	"ENH": ["Enhanced risk", Color("f0a640")],
	"MDT": ["Moderate risk", Color("f05050")],
	"HIGH": ["High risk", Color("ff66ff")],
}

var enabled := false
var _cache: Dictionary = {}  # "YYYY-MM-DD/cycle" -> {fetched: unix, areas: Array, failed?}
var _requests: Dictionary = {}  # key -> HTTPRequest


## The categorical areas of the Day 1 outlook in effect at unix time `t`, lowest risk first:
## [{kind, name, color, issue: unix, rings: Array[PackedVector2Array] (lon, lat),
## polygons: Array of [outer ring, hole rings...]}]. Starts
## the fetches it needs; `changed` follows.
func active_at(t: int) -> Array:
	if not enabled or t <= 0:
		return []
	for dc in issued_by(t):
		var key := "%s/%d" % dc
		_ensure(key, dc[0], dc[1])
		var entry: Dictionary = _cache.get(key, {})
		if entry.is_empty():
			return []  # still loading: nothing rather than an older outlook for a moment
		if not (entry["areas"] as Array).is_empty():
			return entry["areas"]
	return []


## [convective day "YYYY-MM-DD", cycle] of the Day 1 outlooks issued by unix time `t` for the
## day containing it, latest first.
static func issued_by(t: int) -> Array:
	var date := Time.get_date_string_from_unix_time(t - 12 * 3600)
	var day_start := Time.get_unix_time_from_datetime_string(date)
	var out := []
	for c in CYCLES:
		var hour := c + 24 if c < 6 else c  # the 01Z outlook comes out the next calendar day
		var at: int = day_start + hour * 3600 + ISSUE_MIN[c] * 60
		if at <= t:
			out.push_front([date, c])
	return out


func _ensure(key: String, date: String, cycle: int) -> void:
	if _requests.has(key):
		return
	var now := int(Time.get_unix_time_from_system())
	var entry: Dictionary = _cache.get(key, {})
	if not entry.is_empty():
		var recent := now - Time.get_unix_time_from_datetime_string(date) < RECENT_SEC + 36 * 3600
		var empty_or_failed: bool = (
			entry.get("failed", false) or (entry["areas"] as Array).is_empty()
		)
		if not (recent and empty_or_failed and now - int(entry["fetched"]) >= RETRY_SEC):
			return
	var req := HTTPRequest.new()
	req.timeout = 30.0
	add_child(req)
	_requests[key] = req
	req.request_completed.connect(_on_fetched.bind(key, req))
	if req.request(URL % [date, cycle]) != OK:
		_on_fetched(
			HTTPRequest.RESULT_CANT_CONNECT, 0, PackedStringArray(), PackedByteArray(), key, req
		)


func _on_fetched(
	result: int,
	code: int,
	_headers: PackedStringArray,
	body: PackedByteArray,
	key: String,
	req: HTTPRequest
) -> void:
	_requests.erase(key)
	req.queue_free()
	var now := int(Time.get_unix_time_from_system())
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("outlook: fetch failed (result %d, HTTP %d)" % [result, code])
		_cache[key] = {"fetched": now, "failed": true, "areas": []}
	else:
		_cache[key] = {"fetched": now, "areas": parse(body.get_string_from_utf8())}
	changed.emit()


## The categorical areas of an IEM spc_outlook.geojson document, lowest risk first.
static func parse(text: String) -> Array:
	var json := JSON.new()
	var out := []
	if json.parse(text) != OK or not json.data is Dictionary:
		return out
	for f in (json.data as Dictionary).get("features", []):
		var p: Dictionary = f.get("properties", {})
		var kind := str(p.get("threshold", ""))
		if p.get("category") != "CATEGORICAL" or not KINDS.has(kind):
			continue
		var rings: Array[PackedVector2Array] = []
		var polygons: Array = []
		var geom: Dictionary = f.get("geometry", {})
		var polys: Array = geom.get("coordinates", [])
		if geom.get("type") == "Polygon":
			polys = [polys]
		for poly in polys:
			var polygon: Array[PackedVector2Array] = []
			for r in poly:  # outer ring and holes
				var ring := PackedVector2Array()
				for c in r:
					ring.append(Vector2(float(c[0]), float(c[1])))
				rings.append(ring)
				polygon.append(ring)
			if not polygon.is_empty():
				polygons.append(polygon)
		var issue := str(p.get("issue", "")).trim_suffix("Z")
		(
			out
			. append(
				{
					"kind": kind,
					"name": KINDS[kind][0],
					"color": KINDS[kind][1],
					"issue": Time.get_unix_time_from_datetime_string(issue) if issue != "" else 0,
					"rings": rings,
					"polygons": polygons,
				}
			)
		)
	out.sort_custom(
		func(a: Dictionary, b: Dictionary) -> bool:
			return KINDS.keys().find(a["kind"]) < KINDS.keys().find(b["kind"])
	)
	return out


## "SPC day 1 (16:30Z): moderate risk" – the highest category anywhere.
static func summary(areas: Array) -> String:
	if areas.is_empty():
		return ""
	var top: Dictionary = areas[-1]
	var at := Time.get_datetime_string_from_unix_time(top["issue"]).substr(11, 5)
	return "SPC day 1 (%sZ): %s" % [at, top["name"].to_lower()]


## The highest-risk area among `areas` containing `lonlat`, or {}.
static func at_point(areas: Array, lonlat: Vector2) -> Dictionary:
	for i in range(areas.size() - 1, -1, -1):
		for polygon in areas[i]["polygons"]:
			if not Geometry2D.is_point_in_polygon(lonlat, polygon[0]):
				continue
			var in_hole := false
			for hole in polygon.slice(1):
				if Geometry2D.is_point_in_polygon(lonlat, hole):
					in_hole = true
					break
			if not in_hole:
				return areas[i]
	return {}
