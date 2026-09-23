extends "res://tests/test_case.gd"
## SPC outlooks from a canned IEM spc_outlook.geojson (no network), and cycle selection.

const SAMPLE := """{"type": "FeatureCollection", "features": [
{"type": "Feature", "properties": {"issue": "2013-05-20T16:30:00Z", "threshold": "MDT",
 "category": "CATEGORICAL"}, "geometry": {"type": "MultiPolygon", "coordinates":
 [[[[-98.0, 35.0], [-97.0, 35.0], [-97.0, 36.0], [-98.0, 36.0], [-98.0, 35.0]]]]}},
{"type": "Feature", "properties": {"issue": "2013-05-20T16:30:00Z", "threshold": "0.10",
 "category": "TORNADO"}, "geometry": {"type": "MultiPolygon", "coordinates":
 [[[[-99.0, 34.0], [-96.0, 34.0], [-96.0, 37.0], [-99.0, 34.0]]]]}},
{"type": "Feature", "properties": {"issue": "2013-05-20T16:30:00Z", "threshold": "SLGT",
 "category": "CATEGORICAL"}, "geometry": {"type": "Polygon", "coordinates":
 [[[-100.0, 33.0], [-95.0, 33.0], [-95.0, 38.0], [-100.0, 38.0], [-100.0, 33.0]]]}}
]}"""

const HOLES := """{"type": "FeatureCollection", "features": [
{"properties": {"threshold": "SLGT", "category": "CATEGORICAL"},
 "geometry": {"type": "Polygon", "coordinates": [
 [[0,0], [10,0], [10,10], [0,10], [0,0]]]}},
{"properties": {"threshold": "MDT", "category": "CATEGORICAL"},
 "geometry": {"type": "MultiPolygon", "coordinates": [
 [[[1,1], [4,1], [4,4], [1,4], [1,1]],
  [[2,2], [3,2], [3,3], [2,3], [2,2]]],
 [[[11,1], [14,1], [14,4], [11,4], [11,1]],
  [[12,2], [13,2], [13,3], [12,3], [12,2]]]]}},
{"properties": {"threshold": "HIGH", "category": "CATEGORICAL"},
 "geometry": {"type": "Polygon", "coordinates": [
 [[5,1], [8,1], [8,4], [5,4], [5,1]],
 [[6,2], [7,2], [7,3], [6,3], [6,2]]]}}
]}"""


func _unix(iso: String) -> int:
	return Time.get_unix_time_from_datetime_string(iso)


func test_parse_and_query() -> void:
	var areas := Outlooks.parse(SAMPLE)
	check_eq(areas.size(), 2, "categorical only")
	check_eq([areas[0]["kind"], areas[1]["kind"]], ["SLGT", "MDT"], "lowest risk first")
	check_eq(areas[1]["issue"], _unix("2013-05-20T16:30:00"), "issue time")
	check_eq(Outlooks.summary(areas), "SPC day 1 (16:30Z): moderate risk", "summary")
	check_eq(Outlooks.at_point(areas, Vector2(-97.5, 35.5))["kind"], "MDT", "inside both: MDT")
	check_eq(Outlooks.at_point(areas, Vector2(-99.5, 35.5))["kind"], "SLGT", "slight only")
	check(Outlooks.at_point(areas, Vector2(-90.0, 35.5)).is_empty(), "outside")


func test_polygon_holes() -> void:
	var areas := Outlooks.parse(HOLES)
	check_eq(areas.size(), 3, "all categorical geometries parse")
	check_eq(areas[1]["rings"].size(), 4, "all multipolygon rings remain drawable")
	check_eq(areas[1]["polygons"].size(), 2, "multipolygon boundaries stay grouped")
	check_eq(Outlooks.at_point(areas, Vector2(1.5, 1.5))["kind"], "MDT", "first outer")
	check_eq(
		Outlooks.at_point(areas, Vector2(2.5, 2.5))["kind"], "SLGT", "first hole falls through"
	)
	check_eq(Outlooks.at_point(areas, Vector2(11.5, 1.5))["kind"], "MDT", "second outer")
	check(Outlooks.at_point(areas, Vector2(12.5, 2.5)).is_empty(), "second hole excludes area")
	check_eq(Outlooks.at_point(areas, Vector2(5.5, 1.5))["kind"], "HIGH", "polygon outer")
	check_eq(
		Outlooks.at_point(areas, Vector2(6.5, 2.5))["kind"], "SLGT", "polygon hole falls through"
	)


func test_cycles() -> void:
	check_eq(
		Outlooks.issued_by(_unix("2013-05-20T20:03:59")),
		[["2013-05-20", 20], ["2013-05-20", 16], ["2013-05-20", 13], ["2013-05-20", 6]],
		"afternoon: 20Z first"
	)
	check_eq(
		Outlooks.issued_by(_unix("2013-05-20T16:10:00"))[0], ["2013-05-20", 13], "before 1630Z"
	)
	check_eq(
		Outlooks.issued_by(_unix("2013-05-21T03:00:00"))[0],
		["2013-05-20", 1],
		"after midnight: the previous convective day's 01Z"
	)
	check_eq(
		Outlooks.issued_by(_unix("2013-05-21T12:30:00")), [["2013-05-21", 6]], "a new day at 12Z"
	)


func test_national_context_and_hover() -> void:
	var t := _unix("2013-05-20T20:03:59")
	var context := Overlays.context_for(null, true, t)
	check_eq(context["time"], t, "national uses wall-clock time")
	check_eq(context["center"], NationalComposite.CENTER, "national projection center")
	var volume := RadarVolume.open(lib.source, lib.latest())
	var site_context := Overlays.context_for(volume, false, t)
	check_eq(site_context["time"], RadarLibrary.unix_of(volume.name), "site uses volume time")
	check_eq(
		site_context["center"],
		Vector2(float(volume.meta["latitude"]), float(volume.meta["longitude"])),
		"site uses radar center"
	)
	var areas := Outlooks.parse(SAMPLE)
	var projected := Warnings.project(areas, context["center"].x, context["center"].y)
	var ll := Vector2(-97.5, 35.5)
	var p := Basemap.project(ll.y, ll.x, context["center"].x, context["center"].y)
	var recovered := Basemap.unproject(p, context["center"].x, context["center"].y)
	check(recovered.distance_to(Vector2(ll.y, ll.x)) < 0.0001, "national hover inverse projection")
	check(projected.size() == 2 and projected[1]["rings"].size() == 1, "national outlines")
	var overlays := Overlays.new()
	overlays.active_outlook = areas
	check_eq(
		overlays.readout_lines(ll, Vector2.ZERO),
		PackedStringArray(["SPC day 1: moderate risk"]),
		"national hover category"
	)
	check_eq(overlays.info_lines()[0], Outlooks.summary(areas), "national summary")
	check_eq(
		overlays.overview_readout(Vector2(p.x, -p.y), "KTLX"),
		"KTLX\nClick for recent scans\nSPC day 1: moderate risk",
		"station hint and category together"
	)
	check(Overlays.context_for(null, false, t).is_empty(), "empty site keeps no context")
	overlays.free()
