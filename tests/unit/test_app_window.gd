extends "res://tests/test_case.gd"
## The app on its one time window (issue #39): the main scene, launched headless on the
## fixtures with AppOptions.test_args and a fetcher that starts no process. Startup options,
## the frames the timeline gets, live rolling on, L, arriving scans of a fetch, a finished
## fetch outside the window, and what prune is told.

const TestFetcher := preload("res://tests/unit/test_fetcher.gd")
const FIXTURES := "res://tests/fixtures/volumes"
const T0 := 1714600800  # 2024-05-01T22:00:00Z: the fixtures' first KTST scan
const KTST: Array[String] = ["KTST_20240501_220000", "KTST_20240501_220500"]
const COMMON: Array[String] = [
	"volumes=" + FIXTURES, "basemap=0", "warnings=0", "prefetch=0", "hover=0"
]


func test_time_option_opens_its_half_hour() -> void:
	var main := _launch(["site=KTST", "time=20240501_220500", "live=0"])
	check(main.window.equals(TimeWindow.around(T0 + 300)), "time= ± 30 min")
	check_eq(main.frames, KTST, "the site's scans inside it")
	check_eq(main.frame, 1, "opened on time=")
	check(not main.live, "not live")
	check_eq(main.hud.window_label.text, "2024-05-01 21:35–22:35Z", "the HUD names the window")
	main._toggle_mosaic()
	check_eq(main._neighbors.size(), 1, "KTSU, inside the window, is a mosaic neighbour")
	_close(main)


func test_window_option_bounds_everything() -> void:
	var main := _launch(["site=KTST", "window=20240501_215900/20240501_220100", "mosaic=1"])
	check_eq(main.frames, KTST.slice(0, 1), "only the scan inside window=")
	check_eq(main.frame, 0, "shown")
	check(not main.live, "a fixed window is not live")
	check_eq(main._neighbors.size(), 0, "KTSU (22:02) is outside: no mosaic neighbour")
	check_eq(main._loop_volumes().size(), 1, "the loop (playback, export) is the window's")
	main._step(1)
	check_eq(main.frame, 0, "stepping stays inside")
	_close(main)


func test_event_launch_without_its_scans() -> void:
	var main := _launch(["event=moore2013"])
	check_eq(main.site, "KTLX", "the event's site, though nothing of it is cached")
	check(main.window.equals(TimeWindow.of_event(Events.find("moore2013"))), "its window")
	check_eq(main.frame, -1, "no frame until its scans arrive")
	check(main.volume == null, "nothing on screen")
	check(not main.live, "not live")
	check_eq(main.fetcher.jobs.size(), 1, "its fetch started")
	var job: Fetcher.Job = main.fetcher.jobs[0]
	check(job.kind == "update" and job.has_meta("jump_to"), "an update aimed at the peak")
	check(main.hud.info.text.begins_with("KTLX  waiting for first scan"), main.hud.info.text)
	main.fetcher._finish(job, 1)
	check(main.hud.info.text.begins_with("KTLX  fetch failed"), "a failed fetch stays visible")
	_close(main)


func test_cached_site_outside_the_window() -> void:
	var main := _launch(["site=KTST", "window=20240501_200000/20240501_210000"])
	check_eq(main.frames, [] as Array[String], "nothing in the window")
	check(main.volume == null and main.frame == -1, "nothing shown")
	check(main.hud.info.text.begins_with("KTST  no scans in this window"), main.hud.info.text)
	_close(main)


## An update's scans arrive oldest first; each one nearer the target takes over, scans of
## another time never show, and the finished job lands on the target (the #35 guarantees).
func test_arriving_scans_converge_inside_the_window() -> void:
	var dir := _temp_dir()
	var main := _launch(["volumes=" + dir, "site=KTST", "window=20240501_215000/20240501_222000"])
	main._select_site("KTST")
	check_eq(main.frame, -1, "an empty site shows nothing")
	var job: Fetcher.Job = main.fetcher.start_update(
		"KTST", "", "2024-05-01T21:50Z", "2024-05-01T22:20Z"
	)
	job.set_meta("jump_to", T0 + 300)
	_arrive(main, dir, KTST[0], KTST[0])
	check_eq(main.volume.name, KTST[0], "the first scan shows")
	_arrive(main, dir, KTST[1], "KTST_20240501_230000")  # another time, the same site
	check_eq(main.frames, KTST.slice(0, 1), "a scan outside the window is not a frame")
	check_eq(main.volume.name, KTST[0], "and does not show")
	_arrive(main, dir, KTST[1], KTST[1])
	check_eq(main.volume.name, KTST[1], "the scan nearer the peak takes over")
	_arrive(main, dir, KTST[0], KTST[0])
	check_eq(main.volume.name, KTST[1], "a re-reported older scan does not move it off")
	main.fetcher._finish(job, 0)
	check_eq(main.volume.name, KTST[1], "the finished job lands on the peak")
	check_eq(main.frames, KTST, "the timeline is the window's scans")
	_close(main)
	_remove_dir(dir)


## fetch=latest opens live, but the newest scan may be older than the last hour: the finished
## job re-targets the window so what it fetched is visible (its range when it has one).
func test_finished_update_outside_the_window_retargets_it() -> void:
	var main := _launch(["site=KTST", "window=20240501_200000/20240501_210000"])
	var job: Fetcher.Job = main.fetcher.start_update("KTST")
	job.volumes.append(KTST[1])
	main.fetcher._finish(job, 0)
	check(main.window.equals(TimeWindow.around(T0 + 300)), "the half hour around the scan")
	check_eq(main.volume.name, KTST[1], "shown")
	check(not main.live, "not live")
	job = main.fetcher.start_update("KTST", "", "2024-05-01T21:00Z", "2024-05-01T22:03Z")
	job.volumes.append(KTST[0])
	main.window = TimeWindow.fixed(0, 1)
	main.fetcher._finish(job, 0)
	check_eq(main.window.to_option(), "20240501_210000/20240501_220300", "the job's range")
	check_eq(main.frames, KTST.slice(0, 1), "its scans")
	_close(main)


func test_live_window_rolls_on() -> void:
	TimeWindow.clock_override = T0 + 360  # 22:06
	var main := _launch(["site=KTST"])  # live by default
	check(main.window.live and main.live, "live")
	check_eq(main.frames, KTST, "the last hour")
	check_eq(main.volume.name, KTST[1], "following the newest")
	check_eq(main.hud.window_label.text, "LIVE (last 60 min)", "the HUD says so")
	TimeWindow.clock_override = T0 + 3601  # 23:00:01: the first scan is over an hour old
	main._on_live_tick()
	check_eq(main.frames, KTST.slice(1), "rolled out of the window")
	check_eq([main.frame, main.volume.name], [0, KTST[1]], "the shown frame keeps its place")
	TimeWindow.clock_override = T0 + 3901  # 23:05:01
	main._on_live_tick()
	check_eq(main.frames, [] as Array[String], "nothing left in the last hour")
	check(main.volume == null and main.frame == -1, "nothing shown: it is not live any more")
	check(main.hud.info.text.begins_with("KTST  no scans in this window"), main.hud.info.text)
	TimeWindow.clock_override = -1
	_close(main)


func test_l_freezes_and_reopens_the_window() -> void:
	TimeWindow.clock_override = T0 + 360
	var main := _launch(["site=KTST", "time=20240501_220000", "live=0"])
	check_eq(main.frame, 0, "time=")
	main._set_live(true)  # L
	check(main.window.live and main.live, "L: live")
	check_eq(main.volume.name, KTST[1], "following the newest")
	main._set_live(false)  # L again
	check(not main.window.live and not main.live, "L: off")
	check(main.window.equals(TimeWindow.fixed(T0 + 360 - 3600, T0 + 360)), "frozen where it was")
	check_eq(main.frames, KTST, "the loop on screen stays")
	check_eq(main.volume.name, KTST[1], "and so does the frame")
	main._step(-1)
	check_eq(main.frame, 0, "stepping back")
	main._set_live(true)
	check(main.window.live, "L: a fresh live window")
	main._set_live(true)
	check(main.live, "L when live: still live")
	_close(main)
	TimeWindow.clock_override = -1


## Prune reads data/window.json: written when the window changes and by an hourly heartbeat.
func test_window_file_for_prune() -> void:
	TimeWindow.clock_override = T0 + 360
	var main := _launch(["site=KTST", "time=20240501_220000", "live=0"])
	check_eq(main._window_file, "", "not for a volumes= library (nexrad does not prune it)")
	var dir := _temp_dir()
	main._window_file = dir.path_join("window.json")
	check_eq(main._window_timer.wait_time, 3600.0, "the heartbeat")
	main._set_live(true)
	var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(main._window_file))
	check_eq(doc.get("live"), true, "the change was written: live")
	check_eq(doc.get("from"), "2024-05-01T21:06:00Z", "its start")
	main._set_live(false)
	doc = JSON.parse_string(FileAccess.get_file_as_string(main._window_file))
	check_eq(doc.get("live"), false, "frozen")
	TimeWindow.clock_override = T0 + 7200
	main._window_timer.timeout.emit()
	doc = JSON.parse_string(FileAccess.get_file_as_string(main._window_file))
	check_eq(doc.get("written"), "2024-05-02T00:00:00Z", "the heartbeat keeps it fresh")
	TimeWindow.clock_override = -1
	_close(main)
	_remove_dir(dir)


func _launch(args: Array) -> Node:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	main.fetcher.free()
	var fetcher := TestFetcher.FakeFetcher.new()
	fetcher.web = false
	main.fetcher = fetcher
	var all := COMMON.duplicate()
	all.append_array(args)
	AppOptions.test_args = PackedStringArray(all)
	(Engine.get_main_loop() as SceneTree).root.add_child(main)  # runs _ready
	AppOptions.test_args = PackedStringArray()
	return main


func _close(main: Node) -> void:
	main.get_parent().remove_child(main)
	main.free()


## A copy of the fixture volume `src` arrives under `name` in `dir`, as a fetch writes it.
func _arrive(main: Node, dir: String, src: String, name: String) -> void:
	var from := ProjectSettings.globalize_path(FIXTURES.path_join(src))
	var to := dir.path_join(name)
	DirAccess.make_dir_recursive_absolute(to)
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))
	main._on_volume_written(name)


func _temp_dir() -> String:
	var dir := OS.get_temp_dir().path_join("droplet-app-%d" % Time.get_ticks_usec())
	DirAccess.make_dir_recursive_absolute(dir)
	return dir


func _remove_dir(dir: String) -> void:
	for d in DirAccess.get_directories_at(dir):
		_remove_dir(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)
