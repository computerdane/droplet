class_name MemorySource
extends VolumeSource
## Volumes held in memory, handed over whole: volume.json text plus {sNN_FIELD.bin: bytes},
## the shape nexrad-wasm's decode() returns. add_volume() again with the same name replaces
## it (a live volume that grew) and bumps its version. Thread-safe.
##
## With a budget, adding a volume evicts others until the sweep bytes fit; the web build's 2 GB
## heap cannot keep unlimited live volumes (often >100 MiB each). Volumes whose scan time (from
## the name) lies outside the window set by set_window() go first, oldest first; only then the
## oldest inside it. The volume just added is never evicted. Without a window: oldest first.

const OPEN_END := -1  # set_window(from, OPEN_END): no upper bound, e.g. a live window

var budget_bytes := 0  # 0 = unlimited
var _window_from := 0  # unix seconds, inclusive
var _window_to := 0  # unix seconds, inclusive; OPEN_END: open-ended
var _has_window := false
var _volumes: Dictionary = {}  # name -> {meta: String, version: int, files: Dictionary, bytes: int}
var _bytes := 0
var _next_version := 1
var _mutex := Mutex.new()


func _init(p_budget_bytes := 0) -> void:
	budget_bytes = p_budget_bytes


func add_volume(name: String, volume_json: String, files: Dictionary) -> void:
	var size := 0
	for bytes: PackedByteArray in files.values():
		size += bytes.size()
	_mutex.lock()
	_drop(name)
	_volumes[name] = {
		"meta": volume_json, "version": _next_version, "files": files.duplicate(), "bytes": size
	}
	_next_version += 1
	_bytes += size
	if budget_bytes > 0 and _bytes > budget_bytes:
		var others: Array = _volumes.keys().filter(func(n: String) -> bool: return n != name)
		others.sort_custom(_evicts_before)
		for n: String in others:
			if _bytes <= budget_bytes:
				break
			_drop(n)
	_mutex.unlock()


## Protects scans in [from_unix, to_unix] (inclusive, unix seconds) from eviction while
## others remain. A live window that rolls with the clock passes to_unix = OPEN_END, so later
## scans stay inside without calling this again; its from_unix still needs updating as it rolls.
## Takes effect at the next add_volume().
func set_window(from_unix: int, to_unix: int) -> void:
	_mutex.lock()
	_window_from = from_unix
	_window_to = to_unix
	_has_window = true
	_mutex.unlock()


## Back to plain oldest-first eviction.
func clear_window() -> void:
	_mutex.lock()
	_has_window = false
	_mutex.unlock()


func remove_volume(name: String) -> void:
	_mutex.lock()
	_drop(name)
	_mutex.unlock()


## Sweep bytes held.
func size_bytes() -> int:
	_mutex.lock()
	var out := _bytes
	_mutex.unlock()
	return out


func names() -> PackedStringArray:
	_mutex.lock()
	var out := PackedStringArray(_volumes.keys())
	_mutex.unlock()
	return out


func read_meta(name: String) -> String:
	return _field(name, "meta", "")


func version(name: String) -> int:
	return _field(name, "version", 0)


func read_file(name: String, file: String) -> PackedByteArray:
	_mutex.lock()
	var v: Dictionary = _volumes.get(name, {})
	var bytes: PackedByteArray = v.get("files", {}).get(file, PackedByteArray())
	_mutex.unlock()
	return bytes


func describe() -> String:
	return "memory (%d volumes)" % names().size()


## True if `name`'s scan time lies inside the window (false without one). Mutex held.
func _in_window(name: String) -> bool:
	if not _has_window:
		return false
	var t := RadarLibrary.unix_of(name)
	return t >= _window_from and (_window_to == OPEN_END or t <= _window_to)


## Eviction order: outside the window before inside, then oldest scan first.
func _evicts_before(a: String, b: String) -> bool:
	var ia := _in_window(a)
	var ib := _in_window(b)
	if ia != ib:
		return ib
	return a.right(15) < b.right(15)


func _drop(name: String) -> void:
	if _volumes.has(name):
		_bytes -= _volumes[name]["bytes"]
		_volumes.erase(name)


func _field(name: String, key: String, default: Variant) -> Variant:
	_mutex.lock()
	var out = _volumes.get(name, {}).get(key, default)
	_mutex.unlock()
	return out
