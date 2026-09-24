extends "res://tests/test_case.gd"
## Fetcher job bookkeeping without processes or network: a request identical to a running
## job's does not start another one (issue #31), and runs again once that job has ended.

const FetcherScript := preload("res://scripts/fetcher.gd")


## Records launches instead of running the nexrad CLI.
class FakeFetcher:
	extends "res://scripts/fetcher.gd"
	var launched: Array[PackedStringArray] = []

	func _launch(args: PackedStringArray) -> Dictionary:
		launched.append(args)
		return {"pid": 0, "stdio": null, "stderr": null}

	# No process to kill: end the job as _process would once the process exits.
	func stop(job: Job) -> void:
		if job.running:
			job.stopped = true
			_finish(job, 0)


func _fake() -> FakeFetcher:
	var fetcher := FakeFetcher.new()
	fetcher.web = false
	return fetcher


func test_request_keys() -> void:
	var e := Events.find("moore2013")
	check_eq(
		_key("update", "ktlx ", "", e["from"] + " ", e["to"]),
		_key("update", "KTLX", "", e["from"], e["to"]),
		"site case and whitespace do not matter"
	)
	check_eq(
		_key("update", "KTLX", "2013-05-20T20:00Z", e["from"], e["to"]),
		_key("update", "KTLX", "", e["from"], e["to"]),
		"a range ignores at, as the CLI does"
	)
	var distinct := [
		_key("update", "KTLX"),
		_key("update", "KTLX", "2013-05-20T20:00Z"),
		_key("update", "KTLX", "2013-05-20T20:05Z"),
		_key("update", "KTLX", "", e["from"], e["to"]),
		_key("update", "KTLX", "", e["from"], "2013-05-20T21:00Z"),
		_key("update", "KOUN", "", e["from"], e["to"]),
		_key("live", "KTLX"),
		_key("live", "KOUN"),
	]
	for i in distinct.size():
		for j in i:
			check(distinct[i] != distinct[j], "%s != %s" % [distinct[i], distinct[j]])


func test_repeated_event_start_runs_one_job() -> void:
	var fetcher := _fake()
	var updates := []
	fetcher.job_updated.connect(func(j: FetcherScript.Job) -> void: updates.append(j))
	var e := Events.find("moore2013")
	var job: FetcherScript.Job = Events.start(e, fetcher)
	# Picking the event again, then Start (the form holds the event's range) three times.
	check(Events.start(e, fetcher) == job, "picking the event again returns the running job")
	for i in 3:
		check(fetcher.start_update("KTLX", "", e["from"], e["to"]) == job, "Start %d" % (i + 1))
	check_eq(fetcher.launched.size(), 1, "one process")
	check_eq(fetcher.jobs.size(), 1, "one job")
	check_eq(job.get_meta("jump_to"), Events.unix(e["peak"]), "still jumps to the peak")
	check(job.describe().contains("already running"), "status says it is already running")
	check(updates.size() == 5 and updates[-1] == job, "each repeat refreshes the job lines")
	fetcher._add_line(job, "[1/12] KTLX20130520_193000_V06")
	check(not job.describe().contains("already running"), "cleared by the next output")
	fetcher.stop_all()
	fetcher.free()


func test_repeated_live_and_update_start_one_job_each() -> void:
	var fetcher := _fake()
	var live: FetcherScript.Job = fetcher.start_live("KTLX")
	check(fetcher.start_live("KTLX") == live, "live for the same site")
	var newest: FetcherScript.Job = fetcher.start_update("KTLX")
	check(fetcher.start_update("KTLX") == newest, "newest volume")
	var at: FetcherScript.Job = fetcher.start_update("KTLX", "2013-05-20T20:00Z")
	check(fetcher.start_update("KTLX", "2013-05-20T20:00Z") == at, "volume at a time")
	# Different datasets still run side by side.
	var other: FetcherScript.Job = fetcher.start_live("KOUN")
	var later: FetcherScript.Job = fetcher.start_update("KTLX", "2013-05-20T20:05Z")
	var jobs := [live, newest, at, other, later]
	for i in jobs.size():
		for j in i:
			check(jobs[i] != jobs[j], "jobs %d and %d are separate" % [j, i])
	check_eq(fetcher.launched.size(), 5, "one process per dataset")
	check_eq(fetcher.running_jobs().size(), 5, "all running")
	fetcher.stop_all()
	fetcher.free()


func test_request_runs_again_after_job_ends() -> void:
	var fetcher := _fake()
	var e := Events.find("elreno2013")
	var first: FetcherScript.Job = Events.start(e, fetcher)
	fetcher._finish(first, 0)
	var second: FetcherScript.Job = Events.start(e, fetcher)
	check(second != first and second.running, "after it is done")
	fetcher._finish(second, 1)
	var third: FetcherScript.Job = Events.start(e, fetcher)
	check(third != second and third.running, "after it failed")
	fetcher.stop(third)
	var fourth: FetcherScript.Job = Events.start(e, fetcher)
	check(fourth != third and fourth.running, "after it was stopped")
	var live: FetcherScript.Job = fetcher.start_live("KTLX")
	fetcher.stop_all()
	check(fetcher.start_live("KTLX") != live, "live after Stop all")
	check_eq(fetcher.launched.size(), 6, "every restart launches")
	fetcher.stop_all()
	fetcher.free()


func test_request_runs_again_while_stopping() -> void:
	var fetcher := _fake()
	# Real stop() sets stopped = true and kills the process, but the job has not finished yet
	# (unlike FakeFetcher.stop, which finishes it immediately): set that up directly.
	var first: FetcherScript.Job = fetcher.start_live("KTLX")
	first.stopped = true
	var second: FetcherScript.Job = fetcher.start_live("KTLX")
	check(second != first and second.running, "a job still stopping does not block a restart")
	check_eq(fetcher.launched.size(), 2, "the repeat launches its own process")
	fetcher.stop_all()
	fetcher.free()


## The same instants spelled differently are the same request: an event's window fetched by
## start_window (2013-05-20T19:30:00Z) and Start on the range the panel filled in (…19:30Z).
func test_request_keys_compare_times_as_instants() -> void:
	var e := Events.find("moore2013")
	var w := TimeWindow.of_event(e)
	check_eq(
		_key("update", "KTLX", "", w.iso_from(), w.iso_to()),
		_key("update", "KTLX", "", e["from"], e["to"]),
		"ISO forms"
	)
	check_eq(
		_key("update", "KTLX", "20130520_200000"), _key("update", "KTLX", "2013-05-20T20Z"), "at"
	)
	check(_key("update", "KTLX", "bad") != _key("update", "KTLX"), "a bad time stays itself")
	var fetcher := _fake()
	var job: FetcherScript.Job = Events.start(e, fetcher)
	check(fetcher.start_update("KTLX", "", e["from"], e["to"]) == job, "one job")
	check(fetcher.start_window("KTLX", w) == job, "the window again")
	check_eq(fetcher.launched.size(), 1, "one process")
	fetcher.stop_all()
	fetcher.free()


func test_within_the_window() -> void:
	TimeWindow.clock_override = 1714600800 + 360
	var fixed := TimeWindow.fixed(1714600800 - 1800, 1714600800 + 300)  # 21:30-22:05Z; now 22:06
	var live := TimeWindow.live_window(20)  # 21:46Z on
	var cases := [
		# [kind, at, from, to, in fixed, in live]
		["live", "", "", "", false, true],
		["update", "", "", "", false, true],  # the newest scan: now
		["update", "2024-05-01T22:00Z", "", "", true, true],
		["update", "2024-05-01T21:40Z", "", "", true, false],
		["update", "2013-05-20T20:00Z", "", "", false, false],
		["update", "", "2024-05-01T20:00Z", "2024-05-01T21:30Z", true, false],  # touches
		["update", "", "2024-05-01T20:00Z", "2024-05-01T21:29Z", false, false],
		["update", "", "2024-05-01T22:05Z", "2024-05-02T00:00Z", true, true],
		["update", "", "2024-05-01T22:06Z", "2024-05-02T00:00Z", false, true],
		["update", "bad", "", "", true, true],  # nexrad rejects it
	]
	for c in cases:
		var what := "%s %s %s-%s" % [c[0], c[1], c[2], c[3]]
		check_eq(FetcherScript.within(fixed, c[0], c[1], c[2], c[3]), c[4], what + " (fixed)")
		check_eq(FetcherScript.within(live, c[0], c[1], c[2], c[3]), c[5], what + " (live)")
	TimeWindow.clock_override = -1


func test_stop_outside() -> void:
	TimeWindow.clock_override = 1714600800 + 360
	var fetcher := _fake()
	var live: FetcherScript.Job = fetcher.start_live("KTLX")
	var newest: FetcherScript.Job = fetcher.start_update("KOUN")
	var event: FetcherScript.Job = Events.start(Events.find("moore2013"), fetcher)
	var stopped := fetcher.stop_outside(TimeWindow.live_window())
	check(stopped == ([event] as Array[FetcherScript.Job]), "live: the event's fetch")
	check(live.running and not live.stopped and newest.running, "live and the newest keep on")
	stopped = fetcher.stop_outside(TimeWindow.around(1714600800 - 7200))
	check(stopped == ([live, newest] as Array[FetcherScript.Job]), "a past window: the rest")
	check_eq(fetcher.running_jobs().size(), 0, "none left")
	check_eq(fetcher.stop_outside(TimeWindow.live_window()).size(), 0, "nothing to stop")
	TimeWindow.clock_override = -1
	fetcher.free()


func test_live_backfills_its_span() -> void:
	var fetcher := _fake()
	fetcher.start_live("KTLX")
	fetcher.start_live("KOUN", 25)
	check_eq(
		fetcher.launched[0], PackedStringArray(["live", "KTLX", "--since-minutes", "60"]), "60"
	)
	check_eq(
		fetcher.launched[1], PackedStringArray(["live", "KOUN", "--since-minutes", "25"]), "25"
	)
	check(fetcher.start_live("KOUN", 60) == fetcher.jobs[1], "one follower per site, any span")
	fetcher.stop_all()
	fetcher.free()


func _key(kind: String, site: String, at := "", from := "", to := "") -> String:
	return FetcherScript.request_key(kind, site, at, from, to)
