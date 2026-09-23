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
