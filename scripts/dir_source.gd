class_name DirSource
extends VolumeSource
## Volumes as directories under `root` (data/volumes/<name>/, written by `nexrad`).

const DEFAULT_ROOT := "res://data/volumes"

var root: String
var _updates := {}
var _mutex := Mutex.new()


func _init(p_root: String = "") -> void:
	root = p_root if not p_root.is_empty() else AppOptions.data_path("volumes")


func names() -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	for name in dir.get_directories():
		if FileAccess.file_exists(root.path_join(name).path_join("volume.json")):
			out.append(name)
	return out


func read_meta(name: String) -> String:
	return FileAccess.get_file_as_string(root.path_join(name).path_join("volume.json"))


## Modification time plus completed-write notifications, including same-second replacements.
func version(name: String) -> int:
	var stamp := FileAccess.get_modified_time(root.path_join(name).path_join("volume.json"))
	_mutex.lock()
	var revision: int = _updates.get(name, 0)
	_mutex.unlock()
	return (stamp << 32) + revision


func mark_updated(name: String) -> void:
	_mutex.lock()
	_updates[name] = int(_updates.get(name, 0)) + 1
	_mutex.unlock()


func read_file(name: String, file: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(root.path_join(name).path_join(file))


## Seeks to the two bytes instead of reading the whole file.
func read_half(name: String, file: String, index: int) -> float:
	var f := FileAccess.open(root.path_join(name).path_join(file), FileAccess.READ)
	if f == null or index < 0 or (index + 1) * 2 > f.get_length():
		return NAN
	f.seek(index * 2)
	return f.get_buffer(2).decode_half(0)


func describe() -> String:
	return root
