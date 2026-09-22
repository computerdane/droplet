class_name RadarVolume
extends RefCounted
## One decoded volume: metadata from volume.json plus lazily loaded sweep textures.
## Textures are FORMAT_RH (float16), width = gates, height = azimuth bins.

const MISSING := -1000.0
const RANGE_FOLDED := -2000.0
const FIELDS := ["REF", "VEL", "SW", "ZDR", "PHI", "RHO", "CFP"]

var path: String
var meta: Dictionary
var sweeps: Array = []
var _textures: Dictionary = {}


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
	vol.meta = parsed
	vol.sweeps = parsed.get("sweeps", [])
	return vol


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
	return tex
