class_name RadarLibrary
extends RefCounted
## Index of decoded volumes on disk (data/volumes/<ICAO>_<YYYYMMDD_HHMMSS>/).
## Directory names sort chronologically per site, which is what history browsing needs.

const DEFAULT_ROOT := "res://data/volumes"
## Volumes further apart than this start a new sequence (playback loops within one sequence).
const SEQUENCE_GAP_SEC := 30 * 60

var root: String
var volumes: Array[String] = []  # paths, sorted ascending by (site, time)


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


## [first, last] indices into `list` of the run of volumes around `i` with no gap
## longer than SEQUENCE_GAP_SEC.
static func sequence_bounds(list: Array[String], i: int) -> Vector2i:
	if list.is_empty():
		return Vector2i(-1, -1)
	var lo := i
	var hi := i
	while lo > 0 and unix_of(list[lo]) - unix_of(list[lo - 1]) <= SEQUENCE_GAP_SEC:
		lo -= 1
	while hi < list.size() - 1 and unix_of(list[hi + 1]) - unix_of(list[hi]) <= SEQUENCE_GAP_SEC:
		hi += 1
	return Vector2i(lo, hi)


## Index of the volume in `list` closest in time to `unix`, or -1.
static func nearest_in_time(list: Array[String], unix: int) -> int:
	var best := -1
	var best_d := 0
	for i in list.size():
		var d := absi(unix_of(list[i]) - unix)
		if best < 0 or d < best_d:
			best = i
			best_d = d
	return best


static func site_of(path: String) -> String:
	return path.get_file().get_slice("_", 0)


## Scan start time encoded in the directory name, as unix seconds (UTC).
static func unix_of(path: String) -> int:
	var name := path.get_file()
	var d := name.get_slice("_", 1)
	var t := name.get_slice("_", 2)
	if d.length() != 8 or t.length() != 6:
		return 0
	var dt := {
		"year": d.substr(0, 4).to_int(),
		"month": d.substr(4, 2).to_int(),
		"day": d.substr(6, 2).to_int(),
		"hour": t.substr(0, 2).to_int(),
		"minute": t.substr(2, 2).to_int(),
		"second": t.substr(4, 2).to_int(),
	}
	return Time.get_unix_time_from_datetime_dict(dt)
