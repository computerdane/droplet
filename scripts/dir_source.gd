class_name DirSource
extends VolumeSource
## Volumes as directories under `root` (data/volumes/<name>/, written by `nexrad`).

const DEFAULT_ROOT := "res://data/volumes"

var root: String


func _init(p_root: String = DEFAULT_ROOT) -> void:
	root = p_root


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


## volume.json's modification time (`nexrad` writes it by atomic rename).
func version(name: String) -> int:
	return FileAccess.get_modified_time(root.path_join(name).path_join("volume.json"))


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
