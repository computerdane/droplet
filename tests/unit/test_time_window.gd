extends "res://tests/test_case.gd"
## TimeWindow: the app's one time window (issue #37). No scene, no clock: times are explicit.

const T := 1369080600  # 2013-05-20T20:10:00Z, Moore's peak


func test_fixed_windows() -> void:
	var w := TimeWindow.fixed(100, 200)
	check(not w.live and w.from == 100 and w.to == 200, "fixed")
	w = TimeWindow.around(T)
	check_eq([w.from, w.to], [T - 1800, T + 1800], "time= opens ± 30 min")
	check_eq(TimeWindow.around(T, 60).to - T, 60, "custom half width")
	w = TimeWindow.of_event(Events.find("moore2013"))
	check_eq(w.iso_from(), "2013-05-20T19:30:00Z", "event from")
	check_eq(w.iso_to(), "2013-05-20T20:45:00Z", "event to")


func test_contains_and_filter_boundaries() -> void:
	var w := TimeWindow.fixed(T - 60, T + 60)
	check(w.contains(T - 60) and w.contains(T + 60), "inclusive ends")
	check(not w.contains(T - 61) and not w.contains(T + 61), "one second out")
	var names: Array[String] = [
		"KTLX_20130520_200859",
		"KTLX_20130520_200900",
		"/data/volumes/KTLX_20130520_201100",
		"KTLX_20130520_201101",
	]
	check_eq(w.filter(names), names.slice(1, 3), "filter by scan start, paths too")
	check_eq(w.filter([] as Array[String]), [] as Array[String], "empty")


func test_live_rolls_with_now() -> void:
	var w := TimeWindow.live_window(60, T)
	check(w.live, "live")
	check_eq([w.from, w.to], [T - 3600, T], "last 60 min")
	w.tick(T + 300)
	check_eq([w.from, w.to], [T - 3300, T + 300], "tick rolls it forward")
	check(not w.contains(T - 3301) and w.contains(T - 3300), "from inclusive")
	check(w.contains(T + 900), "no upper bound until the next tick")
	var f := TimeWindow.fixed(1, 2)
	f.tick(T)
	check_eq([f.from, f.to], [1, 2], "tick leaves a fixed window")
	# Different scan intervals: the span is the same, so the scan count differs.
	var fast: Array[String] = []
	var slow: Array[String] = []
	for i in 30:
		fast.append("KTLX_" + TimeWindow._name_time(T + 300 - i * 270))
		slow.append("KFDR_" + TimeWindow._name_time(T + 300 - i * 600))
	check_eq(w.filter(fast).size(), 14, "4.5 min scans in 60 min")
	check_eq(w.filter(slow).size(), 7, "10 min scans in 60 min")


func test_live_default_uses_clock() -> void:
	var w := TimeWindow.live_window()
	var now := int(Time.get_unix_time_from_system())
	check(absi(w.to - now) <= 2 and w.to - w.from == 3600, "default: last 60 min up to now")


func test_labels() -> void:
	check_eq(TimeWindow.live_window(60, T).label(), "LIVE (last 60 min)", "live")
	check_eq(TimeWindow.live_window(90, T).label(), "LIVE (last 90 min)", "live span")
	var moore := TimeWindow.of_event(Events.find("moore2013"))
	check_eq(moore.label(), "2013-05-20 19:30–20:45Z", "same day")
	var bridge := TimeWindow.of_event(Events.find("moore1999"))
	check_eq(bridge.label(), "1999-05-03 22:30–1999-05-04 00:45Z", "cross day")


func test_iso_strings() -> void:
	var w := TimeWindow.fixed(Events.unix("2011-04-27T21:45Z"), Events.unix("2011-04-27T23:45Z"))
	check_eq(w.iso_from(), "2011-04-27T21:45:00Z", "iso from")
	check_eq(w.iso_to(), "2011-04-27T23:45:00Z", "iso to")
	check_eq(TimeWindow.parse_time(w.iso_from()), w.from, "iso round trip")
	var live := TimeWindow.live_window(60, T)
	check_eq(live.iso_to(), "2013-05-20T20:10:00Z", "live iso to is now")


func test_parse_time() -> void:
	check_eq(TimeWindow.parse_time("20130520_201000"), T, "time= format")
	check_eq(TimeWindow.parse_time("2013-05-20T20:10Z"), T, "fetch= format")
	check_eq(TimeWindow.parse_time("2013-05-20T20:10:00Z"), T, "with seconds")
	check_eq(TimeWindow.parse_time("2013-05-20T20:10"), T, "without Z")
	check_eq(TimeWindow.parse_time("2013-05-20"), T - 72600, "date only")
	check_eq(TimeWindow.parse_time("2013-05-20T20Z"), T - 600, "hour only")
	check_eq(TimeWindow.parse_time("2013-05-20 20:10z"), T, "space, lowercase z")
	check_eq(TimeWindow.parse_time("2013-5-20T20:10"), T, "one-digit month")
	check_eq(TimeWindow.parse_time(" 2013-05-20T20:10Z "), T, "surrounding space")
	check_eq(TimeWindow.parse_time("2013-05-20T20:10:05.9Z"), T + 5, "fraction dropped")
	check_eq(TimeWindow.parse_time("2013-05-20T15:10-05:00"), T, "negative offset")
	check_eq(TimeWindow.parse_time("2013-05-21T01:40+05:30"), T, "positive offset")
	check_eq(TimeWindow.parse_time("2013-05-20T21:10+01"), T, "offset hours only")
	check_eq(TimeWindow.parse_time("2000-02-29"), 951782400, "2000 is a leap year")
	check_eq(TimeWindow.parse_time("20240229_000000"), 1709164800, "leap day")
	for bad in [
		"",
		"2013",
		"20130520",
		"20130520_2010",
		"20131320_201000",
		"20130532_201000",
		"20230229_000000",
		"20130520_241000",
		"20130520_206000",
		"19000229_000000",
		"1900-02-29",
		"2100-02-29",
		"2013-02-30T00:00Z",
		"2013-05-20T24:00Z",
		"2013-05-20T20:60Z",
		"2013-05-20T20:10:61Z",
		"2013-05-20T20:10+24:00",
		"2013-05-20T:10Z",
		"2013-05-20Z",
		"2013-05-20T20:10ZZ",
		"2013-05-20T20:10:00:00Z",
		"2013/05/20",
		"x20130520_201000",
		"20130520_201000x",
	]:
		check_eq(TimeWindow.parse_time(bad), -1, "invalid %s" % bad)


func test_option_round_trips() -> void:
	var cases := [
		TimeWindow.of_event(Events.find("moore2013")),
		TimeWindow.around(T + 7),
		TimeWindow.fixed(T, T),
		TimeWindow.live_window(),
		TimeWindow.live_window(15, T),
	]
	for w in cases:
		var back := TimeWindow.parse_option(w.to_option())
		check(back != null and back.equals(w), "round trip %s" % w.to_option())
	check_eq(
		TimeWindow.of_event(Events.find("moore2013")).to_option(),
		"20130520_193000/20130520_204500",
		"fixed option"
	)
	check_eq(TimeWindow.live_window(60, T).to_option(), "live", "default live option")
	check_eq(TimeWindow.live_window(15, T).to_option(), "live:15", "live span option")
	var iso := TimeWindow.parse_option("2013-05-20T19:30Z/2013-05-20T20:45Z")
	check(iso != null and iso.equals(TimeWindow.of_event(Events.find("moore2013"))), "iso option")
	var live := TimeWindow.parse_option("live:90")
	check(live != null and live.live and live.span_sec == 5400, "live:90")


func test_invalid_options() -> void:
	for bad in [
		"",
		"live:",
		"live:0",
		"live:-5",
		"live:1.5",
		"live:x",
		"LIVE",
		"20130520_193000",
		"20130520_204500/20130520_193000",
		"20130520_193000/",
		"a/b",
		"20130520_193000/20130520_204500/20130520_210000",
	]:
		check(TimeWindow.parse_option(bad) == null, "invalid %s" % bad)


func test_equals() -> void:
	check(TimeWindow.fixed(1, 2).equals(TimeWindow.fixed(1, 2)), "same fixed")
	check(not TimeWindow.fixed(1, 2).equals(TimeWindow.fixed(1, 3)), "different to")
	check(not TimeWindow.fixed(1, 2).equals(null), "null")
	check(TimeWindow.live_window(60, 0).equals(TimeWindow.live_window(60, T)), "live ignores now")
	check(not TimeWindow.live_window(60, T).equals(TimeWindow.live_window(30, T)), "live span")
	var live := TimeWindow.live_window(60, T)
	check(not live.equals(TimeWindow.fixed(live.from, live.to)), "live is not fixed")


func test_option_precedence() -> void:
	var moore := TimeWindow.of_event(Events.find("moore2013"))
	var tusc := TimeWindow.parse_option("2011-04-27T21:45Z/2011-04-27T23:45Z")
	var all := {
		"window": "20240501_220000/20240501_230000",
		"event": "moore2013",
		"fetch": "2011-04-27T21:45Z/2011-04-27T23:45Z",
		"time": "20200810_164500",
	}
	var want := TimeWindow.fixed(
		TimeWindow.parse_time("20240501_220000"), TimeWindow.parse_time("20240501_230000")
	)
	check(TimeWindow.from_options(all).equals(want), "window= first")
	all["window"] = "bogus"
	check(TimeWindow.from_options(all).equals(tusc), "invalid window= skipped, then fetch=")
	all.erase("window")
	check(TimeWindow.from_options(all).equals(tusc), "fetch= range before event=")
	all["fetch"] = "2013-05-20/2013-05-21"
	var day := TimeWindow.fixed(T - 72600, T + 13800)
	check(TimeWindow.from_options(all).equals(day), "fetch= date range")
	all["fetch"] = "2011-04-27T22:13Z"
	var at := TimeWindow.around(TimeWindow.parse_time("2011-04-27T22:13Z"))
	check(TimeWindow.from_options(all).equals(at), "fetch=<time> ± 30 min")
	for live in ["live", "latest"]:
		all["fetch"] = live
		check(TimeWindow.from_options(all).equals(TimeWindow.live_window()), "fetch=%s" % live)
	for bad in ["bogus", "2013-05-21/2013-05-20", "a/b"]:
		all["fetch"] = bad
		check(TimeWindow.from_options(all).equals(moore), "fetch=%s skipped, then event=" % bad)
	all.erase("fetch")
	check(TimeWindow.from_options(all).equals(moore), "event= before time=")
	all["event"] = "nope"
	var peak := TimeWindow.around(TimeWindow.parse_time("20200810_164500"))
	check(TimeWindow.from_options(all).equals(peak), "unknown event skipped, then time=")
	all.erase("event")
	check(TimeWindow.from_options(all).equals(peak), "time= ± 30 min")
	check(TimeWindow.from_options({"site": "KTLX"}).equals(TimeWindow.live_window()), "else live")
	check(TimeWindow.from_options({"window": "live:20"}).span_sec == 1200, "window=live:20")


func test_upper() -> void:
	check_eq(TimeWindow.fixed(1, 2).upper(), 2, "fixed: to")
	check_eq(TimeWindow.live_window(60, T).upper(), -1, "live: open-ended")


func test_freeze() -> void:
	var live := TimeWindow.live_window(60, T)
	var frozen := live.freeze(T + 600)
	check(not frozen.live and frozen.equals(TimeWindow.fixed(T + 600 - 3600, T + 600)), "as of now")
	check(live.live and live.to == T, "the live window is untouched")
	TimeWindow.clock_override = T + 60
	check(live.freeze().equals(TimeWindow.fixed(T + 60 - 3600, T + 60)), "the clock by default")
	check(TimeWindow.live_window(60).to == T + 60, "live_window reads the same clock")
	TimeWindow.clock_override = -1
	var fixed := TimeWindow.fixed(1, 2)
	check(fixed.freeze(T).equals(fixed) and fixed.freeze(T) != fixed, "a fixed window: a copy")


func test_write_file() -> void:
	var dir := OS.get_temp_dir().path_join("droplet-window-%d" % Time.get_ticks_usec())
	var path := dir.path_join("data").path_join("window.json")
	var moore := TimeWindow.of_event(Events.find("moore2013"))
	check(moore.write_file(path, T + 100), "written (directories created)")
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check_eq(
		doc,
		{
			"from": "2013-05-20T19:30:00Z",
			"to": "2013-05-20T20:45:00Z",
			"live": false,
			"written": "2013-05-20T20:11:40Z",
		},
		"the format nexrad prune reads"
	)
	check(not FileAccess.file_exists(path + ".tmp"), "the temp file was renamed into place")
	var live := TimeWindow.live_window(60, T)
	check(live.write_file(path, T + 300), "overwritten")
	doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	check_eq(
		doc,
		{
			"from": "2013-05-20T19:15:00Z",
			"to": "2013-05-20T20:15:00Z",
			"live": true,
			"written": "2013-05-20T20:15:00Z",
		},
		"live: its extent as of now, flagged live"
	)
	check_eq(live.to, T, "writing does not tick the window")
	TimeWindow.clock_override = T + 7200
	check(live.write_file(path), "the clock by default")
	doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	check_eq(doc["written"], "2013-05-20T22:10:00Z", "written now")
	TimeWindow.clock_override = -1
	check(not moore.write_file(path.path_join("x")), "unwritable: false (a file is not a dir)")
	for f in [path, path.path_join("x") + ".tmp"]:
		DirAccess.remove_absolute(f)
	DirAccess.remove_absolute(dir.path_join("data"))
	DirAccess.remove_absolute(dir)
