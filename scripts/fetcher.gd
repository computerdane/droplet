class_name Fetcher
extends Node
## Runs the Python sidecar from the UI: `python -m nexrad update ...` for history and
## `python -m nexrad live SITE` for live following, with non-blocking pipes polled every
## frame. Each job keeps its last output line for the HUD and the volume directories it
## reported (names like KTLX_20130520_200359), so main.gd can jump to them.
## Needs the dev shell's `python` on PATH (override with DROPLET_PYTHON) and a project
## directory on disk (res:// as a real folder, i.e. not an exported build).

signal job_updated(job: Job)
signal job_finished(job: Job)

const VOLUME_NAME := "[A-Z0-9]{4}_\\d{8}_\\d{6}"


class Job:
	extends RefCounted
	var kind := ""  # "update" or "live"
	var site := ""
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
	var _partial := {}  # pipe -> text received after its last newline

	func describe() -> String:
		var state := ""
		if stopped:
			state = " stopped"
		elif not running:
			state = " done" if exit_code == 0 else " failed (%d)" % exit_code
		var p := progress + " " if running and not progress.is_empty() else ""
		return "%s %s%s: %s%s" % [site, kind, state, p, last_line.get_file()]


var jobs: Array[Job] = []
var _volume_re := RegEx.create_from_string(VOLUME_NAME)
var _progress_re := RegEx.create_from_string("^\\[\\d+/\\d+\\]")


## Fetch history for `site`: the newest volume, the one at/before `at`, or `from`..`to`
## (ISO times, e.g. 2013-05-20T20:00Z).
func start_update(site: String, at := "", from := "", to := "") -> Job:
	var args := PackedStringArray(["update", site])
	if not from.is_empty() and not to.is_empty():
		args.append_array(["--from", from, "--to", to])
	elif not at.is_empty():
		args.append_array(["--at", at])
	return _start("update", site, args)


func start_live(site: String) -> Job:
	return _start("live", site, PackedStringArray(["live", site]))


func stop(job: Job) -> void:
	if job.running:
		job.stopped = true
		OS.kill(job.pid)


func stop_all() -> void:
	for job in jobs:
		stop(job)


func running_jobs() -> Array[Job]:
	return jobs.filter(func(j: Job) -> bool: return j.running)


func _start(kind: String, site: String, args: PackedStringArray) -> Job:
	var job := Job.new()
	job.kind = kind
	job.site = site
	job.args = args
	var root := ProjectSettings.globalize_path("res://")
	# `python -m nexrad` must find the package; the CLI locates data/ from its own path.
	var path := OS.get_environment("PYTHONPATH")
	if not root in path.split(":"):
		OS.set_environment("PYTHONPATH", root if path.is_empty() else root + ":" + path)
	var python := OS.get_environment("DROPLET_PYTHON")
	var argv := PackedStringArray(["-u", "-m", "nexrad"])
	argv.append_array(args)
	var p := OS.execute_with_pipe(python if not python.is_empty() else "python", argv, false)
	if p.is_empty():
		job.running = false
		job.exit_code = -1
		job.last_line = "could not start python (is the nix dev shell active?)"
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


func _process(_delta: float) -> void:
	for job in jobs:
		if not job.running:
			continue
		var out := _read(job, job.stdio)
		var err := _read(job, job.stderr)
		var changed := out or err
		if not OS.is_process_running(job.pid):
			_read(job, job.stdio)
			_read(job, job.stderr)
			job.running = false
			job.exit_code = OS.get_process_exit_code(job.pid)
			job_updated.emit(job)
			job_finished.emit(job)
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
		if line.is_empty():
			continue
		got = true
		job.last_line = line
		var pm := _progress_re.search(line)
		if pm != null:
			job.progress = pm.get_string()
		var m := _volume_re.search(line)
		if m != null and not job.volumes.has(m.get_string()):
			job.volumes.append(m.get_string())
	return got


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		stop_all()
