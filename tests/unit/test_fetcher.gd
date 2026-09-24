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


func _key(kind: String, site: String, at := "", from := "", to := "") -> String:
	return FetcherScript.request_key(kind, site, at, from, to)
