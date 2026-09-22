class_name RadarVolume
extends RefCounted
## One decoded volume: metadata from volume.json plus lazily loaded sweep textures.
## Textures are FORMAT_RH (float16), width = gates, height = azimuth bins.

const MISSING := -1000.0
const RANGE_FOLDED := -2000.0
const FIELDS := ["REF", "VEL", "SW", "ZDR", "PHI", "RHO", "CFP", "DVEL"]
const ELEVATION_MERGE_DEG := 0.2

var path: String
var meta: Dictionary
var sweeps: Array = []
var mtime := 0  # volume.json modification time when loaded
var texture_bytes := 0  # GPU bytes of textures loaded so far (for VolumeCache budgeting)
var tilt_arrays: Dictionary = {}  # field -> TiltArray (volume rendering), see TiltArray
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


func has_texture(i: int, field_name: String) -> bool:
	return _textures.has("%d:%s" % [i, field_name])


func get_texture(i: int, field_name: String) -> ImageTexture:
	var key := "%d:%s" % [i, field_name]
	if not _textures.has(key):
		var img := read_image(i, field_name)
		if img == null:
			return null
		add_texture(i, field_name, img)
	return _textures[key]


## Sweep indices a view needs for `field_name`: every tilt, or just the one nearest `elev_deg`.
func sweeps_for(field_name: String, elev_deg: float, all_tilts: bool) -> Array[int]:
	if all_tilts:
		return tilts(field_name)
	var i := tilt_near(field_name, elev_deg)
	var out: Array[int] = []
	if i >= 0:
		out.append(i)
	return out


## GPU bytes of one sweep/field texture, from the metadata alone.
func texture_size(i: int, field_name: String) -> int:
	return _gates(i, field_name) * int(sweeps[i]["n_azimuth_bins"]) * 2


## Reads one sweep/field file into an Image. Touches no state, so it is safe to call from a
## worker thread (VolumeCache preloading); add_texture() must then run on the main thread.
func read_image(i: int, field_name: String) -> Image:
	var sw: Dictionary = sweeps[i]
	var f: Dictionary = sw["fields"].get(field_name, {})
	if f.is_empty():
		return null
	var n_gates := int(f["n_gates"])
	var n_bins := int(sw["n_azimuth_bins"])
	var bytes := FileAccess.get_file_as_bytes(path.path_join(f["file"]))
	var expected := n_gates * n_bins * 2
	if bytes.size() != expected:
		push_error(
			"RadarVolume: %s has %d bytes, expected %d" % [f["file"], bytes.size(), expected]
		)
		return null
	return Image.create_from_data(n_gates, n_bins, false, Image.FORMAT_RH, bytes)


## Value of sweep `i` / `field_name` at azimuth `az_deg` and slant range `r_km`, read straight
## from the sweep file (two bytes, no texture needed). Picks the same gate and azimuth bin as
## the shaders' nearest-texel lookup; MISSING outside the gates or if the field is absent.
func value_at(i: int, field_name: String, az_deg: float, r_km: float) -> float:
	if i < 0 or i >= sweep_count():
		return MISSING
	var f: Dictionary = sweeps[i]["fields"].get(field_name, {})
	if f.is_empty():
		return MISSING
	var n_gates := int(f["n_gates"])
	var n_bins := int(sweeps[i]["n_azimuth_bins"])
	var gate := (r_km * 1000.0 - float(f["first_gate_m"])) / float(f["gate_spacing_m"])
	if gate < -0.5 or gate >= n_gates - 0.5:
		return MISSING
	var row := int(fposmod(az_deg, 360.0) / 360.0 * n_bins) % n_bins
	var file := FileAccess.open(path.path_join(f["file"]), FileAccess.READ)
	if file == null:
		return MISSING
	file.seek((row * n_gates + int(floorf(gate + 0.5))) * 2)
	return file.get_buffer(2).decode_half(0)


## CPU twin of storm.gdshaderinc: `v` minus the radial component of `storm` (m/s, +x east,
## +y north) at azimuth `az_deg`, elevation `elev_deg`. Sentinels pass through.
static func storm_relative(v: float, storm: Vector2, az_deg: float, elev_deg: float) -> float:
	if v < -900.0:
		return v
	var az := deg_to_rad(az_deg)
	return v - storm.dot(Vector2(sin(az), cos(az))) * cos(deg_to_rad(elev_deg))


## Uploads an Image from read_image() as the texture for sweep `i` / `field_name`.
func add_texture(i: int, field_name: String, img: Image) -> void:
	var key := "%d:%s" % [i, field_name]
	if _textures.has(key):
		return
	_textures[key] = ImageTexture.create_from_image(img)
	texture_bytes += img.get_data_size()
