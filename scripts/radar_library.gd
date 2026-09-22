class_name RadarLibrary
extends RefCounted
## Index of decoded volumes on disk (data/volumes/<ICAO>_<YYYYMMDD_HHMMSS>/).
## Directory names sort chronologically per site, which is what history browsing needs.

const DEFAULT_ROOT := "res://data/volumes"

var root: String
var volumes: Array[String] = []  # absolute-ish paths, sorted ascending by (site, time)


func _init(p_root: String = DEFAULT_ROOT) -> void:
	root = p_root
	scan()


func scan() -> void:
	volumes.clear()
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for name in dir.get_directories():
		if FileAccess.file_exists(root.path_join(name).path_join("volume.json")):
			volumes.append(root.path_join(name))
	volumes.sort()


func sites() -> Array[String]:
	var out: Array[String] = []
	for v in volumes:
		var site := site_of(v)
		if not out.has(site):
			out.append(site)
	return out


func for_site(site: String) -> Array[String]:
	var out: Array[String] = []
	for v in volumes:
		if site_of(v) == site:
			out.append(v)
	return out


func latest(site: String = "") -> String:
	var list := volumes if site.is_empty() else for_site(site)
	return list[-1] if not list.is_empty() else ""


static func site_of(path: String) -> String:
	return path.get_file().get_slice("_", 0)
