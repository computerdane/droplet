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

## What a view needs of a volume: the tilt nearest an elevation (2D), every tilt (3D cones,
## cross-section), or the TiltArray (3D volume rendering).
enum Need { NEAREST_TILT, ALL_TILTS, TILT_ARRAY }

const DEFAULT_BUDGET_BYTES := 1024 * 1024 * 1024
const ARRAY := -1  # sweep index in a Job spec that stands for the field's TiltArray
const UPLOAD_BYTES_PER_FRAME := 24 * 1024 * 1024


## One background read: sweep/field pairs of one volume, filled in by a worker thread.
class Job:
	extends RefCounted
	var volume: RadarVolume
	var specs: Array = []  # [sweep index or ARRAY, field]
	var images: Array = []  # per spec: Image, Array[Image] (ARRAY) or null; worker-written
	var task_id := -1
	var next := 0  # specs uploaded so far

	func run() -> void:
		for s in specs:
			if s[0] == ARRAY:
				images.append(TiltArray.build_images(volume, s[1]))
			else:
				images.append(volume.read_image(s[0], s[1]))


var source: VolumeSource
var budget_bytes: int
var _volumes: Dictionary = {}  # name -> RadarVolume
var _order: Array[String] = []  # least recently used first
var _pinned: Dictionary = {}  # name -> true
var _jobs: Array[Job] = []  # queued or running, oldest first
var _pending: Dictionary = {}  # "name|sweep:field" -> RadarVolume whose job holds it


func _init(p_source: VolumeSource, p_budget_bytes: int = DEFAULT_BUDGET_BYTES) -> void:
	source = p_source
	budget_bytes = p_budget_bytes


## Returns the cached volume `name`, loading it if needed. With `refresh`, reloads any
## rewritten volume, including complete scans whose temporal solution was finalized.
func get_volume(name: String, refresh := false) -> RadarVolume:
	var vol := _lookup(name, refresh)
	if vol == null:
		return null
	_finish_jobs(vol)
	_touch(name)
	return vol


## Forgets a rewritten volume without waiting for background reads. Existing jobs may finish,
## but their images cannot enter the replacement volume or block its own prefetch jobs.
func invalidate(name: String) -> void:
	_drop(name)


## Volumes currently on screen; they survive eviction until the next call.
func pin(paths: Array) -> void:
	_pinned.clear()
	for p in paths:
		_pinned[p] = true


## Queues a background read of what a view of `field_name` needs of volume `name` (see Need;
## `elev_deg` picks the tilt for NEAREST_TILT). Marks the volume recently used, so prefetch
## upcoming frames in playback order. Skips partial volumes, which are still being written.
## Returns the bytes this volume will hold once loaded (0 if it cannot be loaded).
func prefetch(name: String, field_name: String, elev_deg: float, need: Need) -> int:
	var vol := _lookup(name, false)
	if vol == null:
		return 0
	_touch(name)
	var job := Job.new()
	job.volume = vol
	var total := 0
	var tilts := vol.tilts(field_name)  # memoised here, so workers only read it
	if need == Need.TILT_ARRAY:
		var width := 0
		for i in tilts:
			width = maxi(width, vol.texture_size(i, field_name) / vol.sweep(i)["n_azimuth_bins"])
		total = width * TiltArray.ROWS * tilts.size()
		var key := _key(name, ARRAY, field_name)
		var have := vol.tilt_arrays.has(field_name)
		if vol.is_complete() and not have and not tilts.is_empty() and _pending.get(key) != vol:
			_pending[key] = vol
			job.specs.append([ARRAY, field_name])
	else:
		for i in vol.sweeps_for(field_name, elev_deg, need == Need.ALL_TILTS):
			total += vol.texture_size(i, field_name)
			var key := _key(name, i, field_name)
			var have := vol.has_texture(i, field_name)
			if vol.is_complete() and not have and _pending.get(key) != vol:
				_pending[key] = vol
				job.specs.append([i, field_name])
	if not job.specs.is_empty():
		job.task_id = WorkerThreadPool.add_task(job.run, false, "preload " + name)
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


func _lookup(name: String, refresh: bool) -> RadarVolume:
	var vol: RadarVolume = _volumes.get(name)
	if vol != null and refresh and vol.is_stale():
		_drop(name)
		vol = null
	if vol == null:
		vol = RadarVolume.open(source, name)
		if vol != null:
			_volumes[name] = vol
	return vol


func _touch(name: String) -> void:
	_order.erase(name)
	_order.append(name)
	_evict()


## Uploads up to `budget` bytes of a finished job's images; returns the bytes uploaded.
func _upload(job: Job, budget: int) -> int:
	var used := 0
	while job.next < job.specs.size() and (used < budget or budget < 0):
		var s: Array = job.specs[job.next]
		var result = job.images[job.next]
		job.next += 1
		if result == null or _volumes.get(job.volume.name) != job.volume:
			continue
		if s[0] == ARRAY:
			var layers: Array[Image] = result
			TiltArray.add(job.volume, s[1], layers)
			for img in layers:
				used += img.get_data_size()
		else:
			job.volume.add_texture(s[0], s[1], result)
			used += (result as Image).get_data_size()
	return used


## Waits for the job's task (required to free it) and forgets it.
func _retire(job: Job) -> void:
	WorkerThreadPool.wait_for_task_completion(job.task_id)
	for s in job.specs:
		var key := _key(job.volume.name, s[0], s[1])
		if _pending.get(key) == job.volume:
			_pending.erase(key)
	_jobs.erase(job)


## Blocks until the background reads of `vol` are done and uploads them all.
func _finish_jobs(vol: RadarVolume) -> void:
	for job in _jobs.duplicate():
		if job.volume == vol:
			_retire(job)
			_upload(job, -1)


## Forgets a volume; its jobs still run to completion but their images are dropped.
func _drop(name: String) -> void:
	_volumes.erase(name)
	_order.erase(name)


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


static func _key(name: String, i: int, field_name: String) -> String:
	return "%s|%d:%s" % [name, i, field_name]
