class_name Fetcher
extends Node
## Runs fetch jobs from the UI: `update` for history and `live` for live following. Each job
## keeps its last output line for the HUD and the volume names it reported (like
## KTLX_20130520_200359), so main.gd can jump to them.
##
## Desktop: runs the nexrad CLI (`nexrad update ...`, `nexrad live SITE`) with non-blocking
## pipes polled every frame; it writes volumes to data/volumes. Needs the `nexrad` binary on
## PATH (the dev shell adds nexrad/target/release, filled by `cargo build --release`; override
## with DROPLET_NEXRAD) and a writable data root (DROPLET_ROOT, or the source checkout).
##
## Web: one Web Worker per job (web/nexrad_worker.js, running nexrad-wasm next to index.html),
## which fetches straight from the Unidata buckets and hands each decoded volume over whole;
## volume_received passes it on for a MemorySource.
##
## A request identical to a running job's (same `request_key`: kind, site and times) does not
## start another job: start_update/start_live return the running one, flagged "already running"
## in its status line until its next output. Once it has finished, the request runs again.

signal job_updated(job: Job)
signal job_finished(job: Job)
## Web only: a decoded volume (`files` = {sNN_FIELD.bin: PackedByteArray}), before the
## job_updated that reports its name.
signal volume_received(name: String, volume_json: String, files: Dictionary)
## Desktop only: a completed write, including a replacement of the same volume name.
signal volume_written(name: String)

const VOLUME_NAME := "[A-Z0-9]{4}_\\d{8}_\\d{6}"
const WORKER_URL := "nexrad_worker.js"
## localStorage key prefix (+ site) of where the chunks ring was, the live worker's start hint.
const RING_KEY := "droplet.live_ring."


class Job:
	extends RefCounted
	var kind := ""  # "update" or "live"
	var site := ""
	var key := ""  # request_key() of the request that started it
	var args := PackedStringArray()
	var pid := -1
	var stdio: FileAccess
	var stderr: FileAccess
	var last_line := ""
	var progress := ""  # latest "[i/n]" from `update`
	var volumes: Array[String] = []  # volume directory names reported, in order
	var running := true
	var stopped := false  # killed from the UI
	var exit_code := 0
	var repeated := false  # the same request was made again while running (until the next line)
	var worker: JavaScriptObject  # web
	var on_message: JavaScriptObject  # web: callbacks must outlive the worker
	var on_error: JavaScriptObject
	var _partial := {}  # pipe -> text received after its last newline

	func describe() -> String:
		var state := ""
		if stopped:
			state = " stopped"
		elif not running:
			state = " done" if exit_code == 0 else " failed (%d)" % exit_code
		elif repeated:
			state = " already running"
		var p := progress + " " if running and not progress.is_empty() else ""
		return "%s %s%s: %s%s" % [site, kind, state, p, last_line.get_file()]


var jobs: Array[Job] = []
var web := OS.has_feature("web")
## Live following sleeps with Atomics.wait in the worker, which needs a cross-origin isolated page.
var can_live := true  # set in _ready
var _volume_re := RegEx.create_from_string(VOLUME_NAME)
var _progress_re := RegEx.create_from_string("^\\[\\d+/\\d+\\]")
var _live_volume_re := RegEx.create_from_string(
	"^" + VOLUME_NAME + ": \\d+ sweeps \\(\\d+ chunks\\)( complete)?$"
)


func _ready() -> void:
	if web:
		can_live = JavaScriptBridge.eval("self.crossOriginIsolated === true", true) == true


## Fetch history for `site`: the newest volume, the one at/before `at`, or `from`..`to`
## (ISO times, e.g. 2013-05-20T20:00Z).
## Returns the already running job instead when the same request is running.
func start_update(site: String, at := "", from := "", to := "") -> Job:
	var key := request_key("update", site, at, from, to)
	var running := _repeat(key)
	if running != null:
		return running
	if web:
		return _start_worker("update", site, key, {"at": at, "from": from, "to": to})
	var args := PackedStringArray(["update", site])
	if not from.is_empty() and not to.is_empty():
		args.append_array(["--from", from, "--to", to])
	elif not at.is_empty():
		args.append_array(["--at", at])
	return _start("update", site, key, args)


## Returns the already running job instead when `site` is already being followed.
func start_live(site: String) -> Job:
	var key := request_key("live", site)
	var running := _repeat(key)
	if running != null:
		return running
	if web:
		var request := {}
		var stored := _storage_get(RING_KEY + site)
		var hint = JSON.parse_string(stored) if not stored.is_empty() else null
		if hint is Dictionary:
			request["hint"] = hint
		return _start_worker("live", site, key, request)
	return _start("live", site, key, PackedStringArray(["live", site]))


## Identifies a request's dataset: the kind, the site, and for `update` what it selects, as
## the CLI reads it (a range needs both ends, else the volume at `at`, else the newest).
static func request_key(kind: String, site: String, at := "", from := "", to := "") -> String:
	var parts := PackedStringArray([kind, site.strip_edges().to_upper()])
	if kind == "update":
		var a := at.strip_edges()
		var f := from.strip_edges()
		var t := to.strip_edges()
		if not f.is_empty() and not t.is_empty():
			parts.append_array(["range", f, t])
		elif not a.is_empty():
			parts.append_array(["at", a])
		else:
			parts.append("newest")
	return " ".join(parts)


## The running job started for `key`, or null (one being stopped does not count).
func running_job(key: String) -> Job:
	for job in jobs:
		if job.running and not job.stopped and job.key == key:
			return job
	return null


## A repeated request: flags the running job for `key` and returns it (null if none).
func _repeat(key: String) -> Job:
	var job := running_job(key)
	if job != null:
		job.repeated = true
		job_updated.emit(job)
	return job


func stop(job: Job) -> void:
	if job.running:
		job.stopped = true
		if job.worker != null:
			job.worker.terminate()
			_finish(job, 0)
		else:
			OS.kill(job.pid)


func stop_all() -> void:
	for job in jobs:
		stop(job)


func running_jobs() -> Array[Job]:
	return jobs.filter(func(j: Job) -> bool: return j.running)


## Status lines of the running jobs, or of the last job if it failed: a fetch that ended without
## a scan must say so in the HUD rather than leave the view silently where it was.
func status_lines() -> PackedStringArray:
	var out := PackedStringArray()
	for job in running_jobs():
		out.append(job.describe())
	var last: Job = jobs.back() if not jobs.is_empty() else null
	if out.is_empty() and last != null and last.exit_code != 0 and not last.stopped:
		out.append(last.describe())
	return out


## Fetches a site the user just picked on the map: live following when possible, else its
## newest scan; nothing when a job for it is already running.
func start_site(site: String) -> void:
	for j in running_jobs():
		if j.site == site:
			return
	if can_live:
		start_live(site)
	else:
		start_update(site)


func _start(kind: String, site: String, key: String, args: PackedStringArray) -> Job:
	var job := Job.new()
	job.kind = kind
	job.site = site
	job.key = key
	job.args = args
	var p := _launch(args)
	if p.is_empty():
		job.running = false
		job.exit_code = -1
		job.last_line = "could not start nexrad (cargo build --release in the dev shell?)"
	else:
		job.pid = p["pid"]
		job.stdio = p["stdio"]
		job.stderr = p["stderr"]
		job.last_line = "starting"
	jobs.append(job)
	job_updated.emit(job)
	if not job.running:
		job_finished.emit(job)
	return job


## Runs the nexrad CLI with `args`: OS.execute_with_pipe's {stdio, stderr, pid}, or {} if it
## could not start. (Tests override this to run without a process.)
func _launch(args: PackedStringArray) -> Dictionary:
	# The CLI resolves data/ under DROPLET_ROOT.
	if OS.get_environment("DROPLET_ROOT").is_empty():
		OS.set_environment("DROPLET_ROOT", ProjectSettings.globalize_path("res://"))
	var exe := OS.get_environment("DROPLET_NEXRAD")
	return OS.execute_with_pipe(exe if not exe.is_empty() else "nexrad", args, false)


func _start_worker(kind: String, site: String, key: String, request: Dictionary) -> Job:
	var job := Job.new()
	job.kind = kind
	job.site = site
	job.key = key
	request["cmd"] = kind
	request["site"] = site
	job.args = PackedStringArray([JSON.stringify(request)])
	var opts: JavaScriptObject = JavaScriptBridge.create_object("Object")
	opts.type = "module"
	job.worker = JavaScriptBridge.create_object("Worker", WORKER_URL, opts)
	job.on_message = JavaScriptBridge.create_callback(_on_worker_message.bind(job))
	job.on_error = JavaScriptBridge.create_callback(_on_worker_error.bind(job))
	job.worker.onmessage = job.on_message
	job.worker.onerror = job.on_error
	job.worker.postMessage(job.args[0])
	job.last_line = "starting"
	jobs.append(job)
	job_updated.emit(job)
	return job


func _on_worker_message(args: Array, job: Job) -> void:
	if not job.running:
		return
	var data: JavaScriptObject = args[0].data
	match str(data.type):
		"line":
			_add_line(job, str(data.line))
		"volume":
			var files := {}
			var names: JavaScriptObject = data.names
			for i in int(names.length):
				var buf: JavaScriptObject = data.buffers.at(i)
				files[str(names.at(i))] = JavaScriptBridge.js_buffer_to_packed_byte_array(buf)
			var name := str(data.name)
			volume_received.emit(name, str(data.volume_json), files)
			if not job.volumes.has(name):
				job.volumes.append(name)
		"ring":
			var ring := {"volume": int(data.volume), "time_ms": float(data.time_ms)}
			_storage_set(RING_KEY + job.site, JSON.stringify(ring))
		"done":
			job.worker.terminate()
			_finish(job, 0)
			return
		"error":
			job.last_line = str(data.message)
			job.worker.terminate()
			_finish(job, 1)
			return
	job_updated.emit(job)


## localStorage on web ("" when missing or when the page may not use it).
func _storage_get(key: String) -> String:
	var v = JavaScriptBridge.eval(
		(
			"(() => { try { return localStorage.getItem(%s) || ''; } catch (e) { return ''; } })()"
			% JSON.stringify(key)
		),
		true
	)
	return str(v) if v != null else ""


func _storage_set(key: String, value: String) -> void:
	JavaScriptBridge.eval(
		(
			"(() => { try { localStorage.setItem(%s, %s); } catch (e) {} })()"
			% [JSON.stringify(key), JSON.stringify(value)]
		),
		true
	)


## Uncaught worker errors, e.g. nexrad_worker.js or the wasm module failing to load.
func _on_worker_error(args: Array, job: Job) -> void:
	if job.running:
		args[0].preventDefault()
		job.last_line = "worker failed: %s" % str(args[0].message)
		job.worker.terminate()
		_finish(job, 1)


func _finish(job: Job, exit_code: int) -> void:
	job.running = false
	job.exit_code = exit_code
	job_updated.emit(job)
	job_finished.emit(job)


func _process(_delta: float) -> void:
	for job in jobs:
		if not job.running or job.worker != null:
			continue
		var out := _read(job, job.stdio)
		var err := _read(job, job.stderr)
		var changed := out or err
		if not OS.is_process_running(job.pid):
			_read(job, job.stdio)
			_read(job, job.stderr)
			_finish(job, OS.get_process_exit_code(job.pid))
		elif changed:
			job_updated.emit(job)
	# Keep finished jobs around briefly for the HUD, but not forever.
	while jobs.size() > 8 and not jobs[0].running:
		jobs.pop_front()


## Reads what is available on one pipe; returns true if a full line arrived.
func _read(job: Job, pipe: FileAccess) -> bool:
	var data := pipe.get_buffer(1 << 16)
	if data.is_empty():
		return false
	var text: String = job._partial.get(pipe, "") + data.get_string_from_utf8()
	var lines := text.split("\n")
	job._partial[pipe] = lines[-1]
	var got := false
	for i in lines.size() - 1:
		var line := lines[i].strip_edges()
		if not line.is_empty():
			got = true
			_add_line(job, line)
	return got


func _add_line(job: Job, line: String) -> void:
	job.last_line = line
	job.repeated = false
	var pm := _progress_re.search(line)
	if pm != null:
		job.progress = pm.get_string()
	var m := _volume_re.search(line)
	if m != null:
		var name := m.get_string()
		# Both archive paths and live chunk summaries report successful writes.
		if not line.ends_with(name) and _live_volume_re.search(line) == null:
			return
		if not web:
			volume_written.emit(name)
		if not job.volumes.has(name):
			job.volumes.append(name)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		stop_all()
