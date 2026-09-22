class_name VolumeCache
extends RefCounted
## LRU of loaded RadarVolumes so animation loops do not re-read disk or re-upload textures.
## Evicts least recently used volumes once their combined texture bytes exceed the budget;
## pinned volumes (the ones on screen) are never evicted.
##
## Background loading: prefetch() queues a WorkerThreadPool task that reads sweep files
## into Images; poll(), called every frame on the main thread, uploads finished Images as
## textures, a few MB per frame. get_volume() waits for a volume's pending tasks and
## uploads them at once, so a frame the preloader has not finished shows complete.

const DEFAULT_BUDGET_BYTES := 1024 * 1024 * 1024
const UPLOAD_BYTES_PER_FRAME := 24 * 1024 * 1024


## One background read: sweep/field pairs of one volume, filled in by a worker thread.
class Job:
	extends RefCounted
	var volume: RadarVolume
	var specs: Array = []  # [sweep index, field]
	var images: Array = []  # Image or null per spec, written by the worker
	var task_id := -1
	var next := 0  # specs uploaded so far

	func run() -> void:
		for s in specs:
			images.append(volume.read_image(s[0], s[1]))


var budget_bytes: int
var _volumes: Dictionary = {}  # path -> RadarVolume
var _order: Array[String] = []  # least recently used first
var _pinned: Dictionary = {}  # path -> true
var _jobs: Array[Job] = []  # queued or running, oldest first
var _pending: Dictionary = {}  # "path|sweep:field" -> true while a job holds it


func _init(p_budget_bytes: int = DEFAULT_BUDGET_BYTES) -> void:
	budget_bytes = p_budget_bytes


## Returns the cached volume for `path`, loading it if needed. Incomplete (live) volumes are
## reloaded when `refresh` is set and the sidecar has rewritten them since.
func get_volume(path: String, refresh := false) -> RadarVolume:
	var vol := _lookup(path, refresh)
	if vol == null:
		return null
	_finish_jobs(vol)
	_touch(path)
	return vol


## Volumes currently on screen; they survive eviction until the next call.
func pin(paths: Array) -> void:
	_pinned.clear()
	for p in paths:
		_pinned[p] = true


## Queues a background read of the textures of `path` that a view of `field_name` needs
## (every tilt, or the one nearest `elev_deg`). Marks the volume recently used, so preload
## upcoming frames in playback order. Skips partial volumes, which are still being written.
## Returns the bytes this volume will hold once loaded (0 if it cannot be loaded).
func prefetch(path: String, field_name: String, elev_deg: float, all_tilts: bool) -> int:
	var vol := _lookup(path, false)
	if vol == null:
		return 0
	_touch(path)
	var job := Job.new()
	job.volume = vol
	var total := 0
	for i in vol.sweeps_for(field_name, elev_deg, all_tilts):
		total += vol.texture_size(i, field_name)
		var key := _key(path, i, field_name)
		if vol.is_complete() and not vol.has_texture(i, field_name) and not _pending.has(key):
			_pending[key] = true
			job.specs.append([i, field_name])
	if not job.specs.is_empty():
		job.task_id = WorkerThreadPool.add_task(job.run, false, "preload " + path.get_file())
		_jobs.append(job)
	return total


## Main thread, once per frame: uploads textures from finished background reads.
func poll() -> void:
	var budget := UPLOAD_BYTES_PER_FRAME
	for job in _jobs.duplicate():
		if budget <= 0:
			break
		if not WorkerThreadPool.is_task_completed(job.task_id):
			continue  # later jobs may be done: workers run several at once
		budget -= _upload(job, budget)
		if job.next == job.specs.size():
			_retire(job)
	_evict()


func pending_jobs() -> int:
	return _jobs.size()


func used_bytes() -> int:
	var total := 0
	for v in _volumes.values():
		total += (v as RadarVolume).texture_bytes
	return total


func _lookup(path: String, refresh: bool) -> RadarVolume:
	var vol: RadarVolume = _volumes.get(path)
	if vol != null and refresh and not vol.is_complete() and vol.is_stale():
		_drop(path)
		vol = null
	if vol == null:
		vol = RadarVolume.load_from_dir(path)
		if vol != null:
			_volumes[path] = vol
	return vol


func _touch(path: String) -> void:
	_order.erase(path)
	_order.append(path)
	_evict()


## Uploads up to `budget` bytes of a finished job's images; returns the bytes uploaded.
func _upload(job: Job, budget: int) -> int:
	var used := 0
	while job.next < job.specs.size() and (used < budget or budget < 0):
		var s: Array = job.specs[job.next]
		var img: Image = job.images[job.next]
		job.next += 1
		if img != null and _volumes.get(job.volume.path) == job.volume:
			job.volume.add_texture(s[0], s[1], img)
			used += img.get_data_size()
	return used


## Waits for the job's task (required to free it) and forgets it.
func _retire(job: Job) -> void:
	WorkerThreadPool.wait_for_task_completion(job.task_id)
	for s in job.specs:
		_pending.erase(_key(job.volume.path, s[0], s[1]))
	_jobs.erase(job)


## Blocks until the background reads of `vol` are done and uploads them all.
func _finish_jobs(vol: RadarVolume) -> void:
	for job in _jobs.duplicate():
		if job.volume == vol:
			_retire(job)
			_upload(job, -1)


## Forgets a volume; its jobs still run to completion but their images are dropped.
func _drop(path: String) -> void:
	_volumes.erase(path)
	_order.erase(path)


func _evict() -> void:
	var used := used_bytes()
	var i := 0
	# Never evict the most recent entry or a pinned one: they are on screen.
	while used > budget_bytes and i < _order.size() - 1:
		var p := _order[i]
		if _pinned.has(p):
			i += 1
			continue
		used -= (_volumes[p] as RadarVolume).texture_bytes
		_drop(p)


static func _key(path: String, i: int, field_name: String) -> String:
	return "%s|%d:%s" % [path, i, field_name]
