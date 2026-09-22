extends "res://tests/test_case.gd"
## NWS warnings from an IEM sbw.geojson document (canned; no network).

const SAMPLE := """{"type": "FeatureCollection", "features": [
{"type": "Feature", "properties": {"phenomena": "TO", "significance": "W", "wfo": "OUN",
 "eventid": 26, "polygon_begin": "2013-05-20T20:01:00Z", "polygon_end": "2013-05-20T20:45:00Z",
 "is_emergency": true, "is_pds": false},
 "geometry": {"type": "MultiPolygon", "coordinates": [[[[-97.6, 35.3], [-97.3, 35.3],
 [-97.3, 35.4], [-97.6, 35.4], [-97.6, 35.3]]]]}},
{"type": "Feature", "properties": {"phenomena": "SV", "significance": "W", "wfo": "OUN",
 "eventid": 320, "polygon_begin": "2013-05-20T20:07:00Z", "polygon_end": "2013-05-20T21:00:00Z",
 "is_emergency": false, "is_pds": false},
 "geometry": {"type": "Polygon", "coordinates": [[[-98.0, 34.5], [-97.5, 34.5], [-97.5, 35.0],
 [-98.0, 34.5]]]}},
{"type": "Feature", "properties": {"phenomena": "FL", "significance": "W", "wfo": "OUN",
 "eventid": 3, "polygon_begin": "2013-05-20T12:00:00Z", "polygon_end": "2013-05-21T12:00:00Z"},
 "geometry": {"type": "Polygon", "coordinates": [[[-97.0, 35.0], [-96.9, 35.0], [-96.9, 35.1]]]}}
]}"""


func test_parse_and_query() -> void:
	var ws := Warnings.parse(SAMPLE)
	check_eq(ws.size(), 2, "tornado and severe thunderstorm kept, river flood left out")
	var to: Dictionary = ws[0]
	check_eq(to["kind"], "TO", "kind")
	check_eq(to["begin"], Time.get_unix_time_from_datetime_string("2013-05-20T20:01:00"), "begin")
	check_eq((to["rings"] as Array).size(), 1, "one ring")
	check_eq(Warnings.describe(to), "Tornado Warning EMERGENCY  OUN 26 until 20:45Z", "describe")
	var moore := Vector2(-97.49, 35.34)  # lon, lat
	var inside := Warnings.containing(ws, moore)
	check(inside.size() == 1 and inside[0] == to, "Moore is in the tornado warning only")
	check_eq(Warnings.containing(ws, Vector2(-96.0, 36.0)), [], "Tulsa is in neither")
	check_eq(Warnings.summary(ws), "1 tornado, 1 severe thunderstorm", "summary")
	# Projected around KTLX: the tornado polygon's corners are a few tens of km away, and the
	# 2D view's frame has +y south.
	var polys := Warnings.project(ws, 35.333, -97.278)
	var ring: PackedVector2Array = polys[0]["rings"][0]
	check_eq(ring.size(), 5, "ring points")
	check(ring[0].x < -25.0 and ring[0].x > -35.0, "west corner %.1f km" % ring[0].x)
	check(ring[2].y < -5.0, "north side above the radar (y %.1f)" % ring[2].y)
	check_eq(Warnings.parse("not json"), [], "garbage")
