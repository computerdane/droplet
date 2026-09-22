class_name RadarVolume
extends RefCounted
## One decoded volume: metadata from volume.json plus lazily loaded sweep textures.
## Textures are FORMAT_RH (float16), width = gates, height = azimuth bins.

const MISSING := -1000.0
const RANGE_FOLDED := -2000.0
const FIELDS := ["REF", "VEL", "SW", "ZDR", "PHI", "RHO", "CFP"]
const ELEVATION_MERGE_DEG := 0.2

var path: String
var meta: Dictionary
var sweeps: Array = []
var mtime := 0  # volume.json modification time when loaded
var texture_bytes := 0  # GPU bytes of textures loaded so far (for VolumeCache budgeting)
var _textures: Dictionary = {}
var _tilts: Dictionary = {}  # field -> Array[int], memoised


static func load_from_dir(dir: String) -> RadarVolume:
	var text := FileAccess.get_file_as_string(dir.path_join("volume.json"))
	if text.is_empty():
		push_error("RadarVolume: cannot read %s/volume.json" % dir)
		return null
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("RadarVolume: bad JSON in %s" % dir)
		return null
	var vol := RadarVolume.new()
	vol.path = dir
	vol.mtime = FileAccess.get_modified_time(dir.path_join("volume.json"))
	vol.meta = parsed
	vol.sweeps = parsed.get("sweeps", [])
	return vol


## True if the sidecar has rewritten volume.json since this was loaded.
func is_stale() -> bool:
	return FileAccess.get_modified_time(path.path_join("volume.json")) != mtime


func icao() -> String:
	return meta.get("icao", "????")


func time_utc() -> String:
	return meta.get("time", "")


func is_complete() -> bool:
	return meta.get("complete", true)


func sweep_count() -> int:
	return sweeps.size()


func sweep(i: int) -> Dictionary:
	return sweeps[i]


func has_field(i: int, field_name: String) -> bool:
	return sweeps[i]["fields"].has(field_name)


func fields_of(i: int) -> Array:
	return sweeps[i]["fields"].keys()


## Index of the nearest sweep to `i` that carries `field_name`, or -1.
func nearest_sweep_with(i: int, field_name: String) -> int:
	for d in range(sweep_count()):
		for j in [i - d, i + d]:
			if j >= 0 and j < sweep_count() and has_field(j, field_name):
				return j
	return -1


func elevation(i: int) -> float:
	return float(sweeps[i]["elevation_deg"])


## Sweep indices carrying `field_name`, one per distinct elevation, sorted by elevation.
## Split cuts and SAILS repeats put several sweeps at ~the same angle; keep the one with
## the most gates (surveillance cut for REF), breaking ties toward the latest sweep.
func tilts(field_name: String) -> Array[int]:
	if _tilts.has(field_name):
		return _tilts[field_name]
	var idx: Array[int] = []
	for i in sweep_count():
		if has_field(i, field_name):
			idx.append(i)
	idx.sort_custom(func(a: int, b: int) -> bool: return elevation(a) < elevation(b))
	var out: Array[int] = []
	for i in idx:
		if not out.is_empty() and elevation(i) - elevation(out[-1]) < ELEVATION_MERGE_DEG:
			var g := _gates(i, field_name)
			var g_kept := _gates(out[-1], field_name)
			if g > g_kept or (g == g_kept and i > out[-1]):
				out[-1] = i
		else:
			out.append(i)
	_tilts[field_name] = out
	return out


## Tilt (sweep index) for `field_name` whose elevation is closest to `elev_deg`, or -1.
func tilt_near(field_name: String, elev_deg: float) -> int:
	var best := -1
	for i in tilts(field_name):
		if best < 0 or absf(elevation(i) - elev_deg) < absf(elevation(best) - elev_deg):
			best = i
	return best


func _gates(i: int, field_name: String) -> int:
	return int(sweeps[i]["fields"][field_name]["n_gates"])


func get_texture(i: int, field_name: String) -> ImageTexture:
	var key := "%d:%s" % [i, field_name]
	if _textures.has(key):
		return _textures[key]
	var sw: Dictionary = sweeps[i]
	var f: Dictionary = sw["fields"].get(field_name, {})
	if f.is_empty():
		return null
	var n_gates := int(f["n_gates"])
	var n_bins := int(sw["n_azimuth_bins"])
	var bytes := FileAccess.get_file_as_bytes(path.path_join(f["file"]))
	if bytes.size() != n_gates * n_bins * 2:
		var expected := n_gates * n_bins * 2
		push_error(
			"RadarVolume: %s has %d bytes, expected %d" % [f["file"], bytes.size(), expected]
		)
		return null
	var img := Image.create_from_data(n_gates, n_bins, false, Image.FORMAT_RH, bytes)
	var tex := ImageTexture.create_from_image(img)
	_textures[key] = tex
	texture_bytes += bytes.size()
	return tex
