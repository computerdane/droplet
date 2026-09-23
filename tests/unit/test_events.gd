extends "res://tests/test_case.gd"
## The notable events list and event= (no network).


func test_events_are_well_formed() -> void:
	var ids := {}
	for e in Events.LIST:
		var from := Events.unix(e["from"])
		var peak := Events.unix(e["peak"])
		var to := Events.unix(e["to"])
		check(from > 0 and from < peak and peak <= to, "%s: from < peak <= to" % e["id"])
		check(to - from <= 4 * 3600, "%s: at most 4 h of volumes" % e["id"])
		check((e["site"] as String).length() == 4, "%s: ICAO site" % e["id"])
		check(not ids.has(e["id"]), "%s: unique id" % e["id"])
		ids[e["id"]] = true
	check_eq(Events.unix("2013-05-20T20:10Z"), 1369080600, "minutes without seconds")
	check_eq(Events.find("moore2013")["site"], "KTLX", "find")
	check(Events.find("nope").is_empty(), "unknown id")
