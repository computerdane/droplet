class_name RadarLibrary
extends RefCounted
## Index of the volumes a VolumeSource holds, by name (<ICAO>_<YYYYMMDD_HHMMSS>).
## Names sort chronologically per site, which is what history browsing needs.

## Volumes further apart than this start a new sequence (playback loops within one sequence).
const SEQUENCE_GAP_SEC := 30 * 60

var source: VolumeSource
var volumes: Array[String] = []  # names, sorted ascending by (site, time)
var _winds: Dictionary = {}  # name -> {version, wind_profile, storm_motion}, see winds()


func _init(p_source: VolumeSource = null) -> void:
	source = p_source if p_source != null else DirSource.new()
	scan()


func scan() -> void:
	volumes.clear()
	for name in source.names():
		volumes.append(name)
	volumes.sort()


## Loads volume `name` from the source, uncached (the app goes through VolumeCache).
func open(name: String) -> RadarVolume:
	return RadarVolume.open(source, name)


func sites() -> Array[String]:
	var out: Array[String] = []
	for v in volumes:
		var site := site_of(v)
		if not out.has(site):
			out.append(site)
	return out


## The volumes of `site`, oldest first; only those inside `window` (a TimeWindow) if given.
func for_site(site: String, window: TimeWindow = null) -> Array[String]:
	var out: Array[String] = []
	for v in volumes:
		if site_of(v) == site and (window == null or window.contains(unix_of(v))):
			out.append(v)
	return out


func latest(site: String = "") -> String:
	var list := volumes if site.is_empty() else for_site(site)
	return list[-1] if not list.is_empty() else ""


## The VAD wind profile and Bunkers storm motion the sidecar stored in volume.json
## (nexrad/src/vad.rs): {"wind_profile": Dictionary or null, "storm_motion": Dictionary or null}.
## Memoised per volume until volume.json changes.
func winds(name: String) -> Dictionary:
	var version := source.version(name)
	var hit: Dictionary = _winds.get(name, {})
	if hit.get("version", -1) == version:
		return hit
	var parsed = JSON.parse_string(source.read_meta(name))
	var meta: Dictionary = parsed if parsed is Dictionary else {}
	hit = {
		"version": version,
		"wind_profile": meta.get("wind_profile"),
		"storm_motion": meta.get("storm_motion"),
	}
	_winds[name] = hit
	return hit


## The storm motion estimate nearest to the volume `name`: its own, else the same
## site's nearest in time, else any other site's, within `max_sec`. Returns
## {"name": source volume, "storm_motion": Dictionary} or {} if there is none.
func storm_motion_near(name: String, max_sec: int) -> Dictionary:
	var t := unix_of(name)
	var site := site_of(name)
	var candidates: Array = []
	for v in volumes:
		var d := absi(unix_of(v) - t)
		if d <= max_sec:
			# Other sites only after every volume of this one (storm motion is regional, but
			# the selected site's own profile is the most representative).
			candidates.append([0 if site_of(v) == site else 1, d, v])
	candidates.sort()
	for c in candidates:
		var sm = winds(c[2]).get("storm_motion")
		if sm is Dictionary:
			return {"name": c[2], "storm_motion": sm}
	return {}


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


static func site_of(name: String) -> String:
	return name.get_file().get_slice("_", 0)


## "HH:MMZ" of a volume name.
static func clock(name: String) -> String:
	var t := name.get_file().get_slice("_", 2)
	return "%s:%sZ" % [t.substr(0, 2), t.substr(2, 2)]


## Scan start time encoded in the volume name, as unix seconds (UTC).
static func unix_of(name: String) -> int:
	var n := name.get_file()
	var d := n.get_slice("_", 1)
	var t := n.get_slice("_", 2)
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
