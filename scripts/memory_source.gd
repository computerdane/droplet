class_name MemorySource
extends VolumeSource
## Volumes held in memory, handed over whole: volume.json text plus {sNN_FIELD.bin: bytes},
## the shape nexrad-wasm's decode() returns. add_volume() again with the same name replaces
## it (a live volume that grew) and bumps its version. Thread-safe.

var _volumes: Dictionary = {}  # name -> {meta: String, version: int, files: Dictionary}
var _next_version := 1
var _mutex := Mutex.new()


func add_volume(name: String, volume_json: String, files: Dictionary) -> void:
	_mutex.lock()
	_volumes[name] = {"meta": volume_json, "version": _next_version, "files": files.duplicate()}
	_next_version += 1
	_mutex.unlock()


func remove_volume(name: String) -> void:
	_mutex.lock()
	_volumes.erase(name)
	_mutex.unlock()


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


func _field(name: String, key: String, default: Variant) -> Variant:
	_mutex.lock()
	var out = _volumes.get(name, {}).get(key, default)
	_mutex.unlock()
	return out
