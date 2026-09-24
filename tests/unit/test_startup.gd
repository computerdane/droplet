extends "res://tests/test_case.gd"
## Launching with event= (issue #35): the frame to open on (the event's window, #39), which
## arriving scans take over the view while the event's loop is fetched, and what the HUD says
## of a fetch that failed. No scene, processes or network: the decisions are Events', the
## window's and Fetcher's (the scene's own are in test_app_window.gd).

const FetcherScript := preload("res://scripts/fetcher.gd")
const TestFetcher := preload("res://tests/unit/test_fetcher.gd")

const EVENT_ID := "moore2013"  # KTLX 19:30-20:45Z, peak 20:10Z
const LOOP: Array[String] = [
	"KTLX_20130520_193000",
	"KTLX_20130520_194500",
	"KTLX_20130520_200500",
	"KTLX_20130520_201000",
	"KTLX_20130520_201500",
	"KTLX_20130520_204500",
]
## A live view of the same site the day before: not the event.
const OTHER_DAY: Array[String] = ["KTLX_20130519_220000", "KTLX_20130519_220500"]


func test_startup_site() -> void:
	var e := Events.find(EVENT_ID)
	var cached: Array[String] = ["KTSU"]
	check_eq(Events.startup_site(e, "KTLX", cached), "KTLX", "the event's site, uncached")
	check_eq(Events.startup_site(e, "KTSU", cached), "KTSU", "a cached site=")
	check_eq(Events.startup_site({}, "KXYZ", cached), "", "an uncached site=: fall back")
	check_eq(Events.startup_site({}, "", cached), "", "no site= nor event=: fall back")
	check_eq(Events.startup_site({}, "", []), "", "an empty library: fall back")


## The frame to open on is the nearest to the peak (or time=) among the site's scans inside
## the event's window, as main._ready decides it; the site's other days are not the event.
func test_startup_frame_is_in_the_event_window() -> void:
	var e := Events.find(EVENT_ID)
	var w := TimeWindow.of_event(e)
	var peak := Events.unix(e["peak"])
	check_eq(_startup_frame(w, [], peak), "", "empty cache: nothing to show")
	check_eq(_startup_frame(w, OTHER_DAY, peak), "", "the site's other scans are not it")
	var partial: Array[String] = OTHER_DAY + LOOP.slice(0, 2)
	check_eq(_startup_frame(w, partial, peak), LOOP[1], "partial cache: nearest scan of the loop")
	var full: Array[String] = OTHER_DAY + LOOP
	check_eq(_startup_frame(w, full, peak), LOOP[3], "full cache: the peak")
	var t := RadarLibrary.unix_of("X_20130520_194000")
	check_eq(_startup_frame(w, full, t), LOOP[1], "an explicit time= within the loop")
	t = RadarLibrary.unix_of("X_20130520_230000")
	check_eq(_startup_frame(w, full, t), LOOP[5], "a time past the loop: its last scan")
	check_eq(w.filter(full), LOOP, "the timeline is the loop alone")


## The scan main opens on (its name, "" for none) with `cached` for the event's site.
static func _startup_frame(w: TimeWindow, cached: Array[String], t: int) -> String:
	var frames := w.filter(cached)
	var i := RadarLibrary.nearest_in_time(frames, t)
	return frames[i] if i >= 0 else ""


func test_arriving_scans_converge_on_peak() -> void:
	var peak := Events.unix(Events.find(EVENT_ID)["peak"])
	var shown := ""
	var history := PackedStringArray()
	for name in LOOP:  # the fetch reports oldest first
		if Events.takes_over(peak, name, shown):
			shown = name
			history.append(name.get_slice("_", 2))
	check_eq(history, PackedStringArray(["193000", "194500", "200500", "201000"]), "path")
	check_eq(shown, LOOP[3], "ends on the peak, before the fetch has finished")
	check(
		not Events.takes_over(peak, LOOP[3], LOOP[3]), "a rewrite of the shown scan is not a move"
	)
	check(Events.takes_over(peak, LOOP[0], ""), "with nothing on screen, the first scan shows")
	check(Events.takes_over(peak, LOOP[0], OTHER_DAY[1]), "the loop replaces the other day")
	for name in LOOP:
		check(not Events.takes_over(peak, name, LOOP[3]), "%s never moves off the peak" % name)


func test_failed_fetch_stays_visible() -> void:
	var fetcher := _fake()
	check_eq(fetcher.status_lines(), PackedStringArray(), "nothing yet")
	var e := Events.find(EVENT_ID)
	var job: FetcherScript.Job = Events.start(e, fetcher)
	check_eq(fetcher.status_lines(), PackedStringArray([job.describe()]), "running")
	fetcher._add_line(job, "nexrad: 2013/05/20/KTLX: connection refused")
	fetcher._finish(job, 1)
	var lines := fetcher.status_lines()
	check_eq(lines.size(), 1, "the failure stays")
	check(lines[0].contains("KTLX update failed (1)"), "as failed: " + lines[0])
	check(lines[0].contains("connection refused"), "with the CLI's last line: " + lines[0])
	var again: FetcherScript.Job = Events.start(e, fetcher)
	check_eq(fetcher.status_lines(), PackedStringArray([again.describe()]), "until the next job")
	fetcher._finish(again, 0)
	check_eq(fetcher.status_lines(), PackedStringArray(), "a finished fetch is not news")
	var stopped: FetcherScript.Job = fetcher.start_live("KTLX")
	fetcher.stop(stopped)
	check_eq(fetcher.status_lines(), PackedStringArray(), "nor a stopped one")
	var no_cli: FetcherScript.Job = fetcher.start_update("KOUN")
	no_cli.running = false
	no_cli.exit_code = -1  # as _start reports a nexrad that could not be run
	check_eq(fetcher.status_lines().size(), 1, "a job that could not start")
	fetcher.stop_all()
	fetcher.free()


func test_start_site_once() -> void:
	var fetcher := _fake()
	fetcher.start_site("KTLX")
	fetcher.start_site("KTLX")
	check_eq(fetcher.jobs.size(), 1, "one job for a site picked twice")
	check_eq(fetcher.jobs[0].kind, "live", "live when the platform allows it")
	fetcher.can_live = false
	fetcher.start_site("KOUN")
	check_eq(fetcher.jobs[-1].kind + " " + fetcher.jobs[-1].site, "update KOUN", "else newest")
	fetcher.stop_all()
	fetcher.free()


func _fake() -> TestFetcher.FakeFetcher:
	var fetcher := TestFetcher.FakeFetcher.new()
	fetcher.web = false
	return fetcher
