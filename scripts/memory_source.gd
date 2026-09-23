class_name MemorySource
extends VolumeSource
## Volumes held in memory, handed over whole: volume.json text plus {sNN_FIELD.bin: bytes},
## the shape nexrad-wasm's decode() returns. add_volume() again with the same name replaces
## it (a live volume that grew) and bumps its version. Thread-safe.
##
## With a budget, adding a volume evicts the oldest others (by scan time) until the sweep bytes
## fit; the web build's 2 GB heap cannot keep unlimited live volumes (often >100 MiB each).

var budget_bytes := 0  # 0 = unlimited
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
		others.sort_custom(func(a: String, b: String) -> bool: return a.right(15) < b.right(15))
		for n: String in others:
			if _bytes <= budget_bytes:
				break
			_drop(n)
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


func _drop(name: String) -> void:
	if _volumes.has(name):
		_bytes -= _volumes[name]["bytes"]
		_volumes.erase(name)


func _field(name: String, key: String, default: Variant) -> Variant:
	_mutex.lock()
	var out = _volumes.get(name, {}).get(key, default)
	_mutex.unlock()
	return out
