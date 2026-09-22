class_name Basemap
extends RefCounted
## Loads data/basemap (built by `python -m nexrad basemap`): line layers as lon/lat meshes
## that basemap_2d/3d.gdshader project around the site on the GPU, and a city list.
## Loaded once and shared; `get_shared()` returns null when the basemap has not been built.

const DEFAULT_ROOT := "res://data/basemap"
const EARTH_RADIUS_KM := 6371.0
## Draw order and style; later layers draw on top.
const LAYER_STYLE := {
	"counties": Color(0.75, 0.8, 0.9, 0.16),
	"states": Color(0.85, 0.9, 1.0, 0.55),
}

static var _shared: Basemap
static var _tried := false

var meshes: Dictionary = {}  # layer -> ArrayMesh (PRIMITIVE_LINES, Vector2 lon/lat vertices)
var cities: Array = []  # [name, lat, lon, population], most populous first


static func get_shared() -> Basemap:
	if not _tried:
		_tried = true
		_shared = load_from_dir(DEFAULT_ROOT)
	return _shared


static func load_from_dir(dir: String) -> Basemap:
	var text := FileAccess.get_file_as_string(dir.path_join("basemap.json"))
	if text.is_empty():
		return null
	var meta = JSON.parse_string(text)
	if not meta is Dictionary:
		push_error("Basemap: bad JSON in %s" % dir)
		return null
	var bm := Basemap.new()
	bm.cities = meta.get("cities", [])
	for layer in LAYER_STYLE:
		var info: Dictionary = meta["layers"].get(layer, {})
		if info.is_empty():
			continue
		var mesh := _load_layer(dir.path_join(info["file"]))
		if mesh != null:
			bm.meshes[layer] = mesh
	return bm


static func _load_layer(path: String) -> ArrayMesh:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() < 8:
		push_error("Basemap: cannot read %s" % path)
		return null
	var n_points := bytes.decode_u32(0)
	var n_indices := bytes.decode_u32(4)
	var xy_end := 8 + n_points * 8
	if bytes.size() != xy_end + n_indices * 4:
		push_error("Basemap: %s is truncated" % path)
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = bytes.slice(8, xy_end).to_vector2_array()
	arrays[Mesh.ARRAY_INDEX] = bytes.slice(xy_end).to_int32_array()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh


## Same azimuthal equidistant projection as basemap.gdshaderinc, in doubles:
## km from the site, +x east, +y north.
static func project(lat: float, lon: float, site_lat: float, site_lon: float) -> Vector2:
	var lat0 := deg_to_rad(site_lat)
	var la := deg_to_rad(lat)
	var dlon := deg_to_rad(lon - site_lon)
	var sdlat := sin(0.5 * (la - lat0))
	var sdlon := sin(0.5 * dlon)
	var hav := sdlat * sdlat + cos(lat0) * cos(la) * sdlon * sdlon
	var c := 2.0 * asin(sqrt(clampf(hav, 0.0, 1.0)))
	var k := 1.0 if c < 1e-9 else c / sin(c)
	var x := k * cos(la) * sin(dlon)
	var y := k * (cos(lat0) * sin(la) - sin(lat0) * cos(la) * cos(dlon))
	return Vector2(x, y) * EARTH_RADIUS_KM


## Cities within `radius_km` of the site as [name, Vector2 km (+y north), population].
func cities_near(site_lat: float, site_lon: float, radius_km: float) -> Array:
	var out := []
	for c in cities:
		var p := project(c[1], c[2], site_lat, site_lon)
		if p.length() <= radius_km:
			out.append([c[0], p, int(c[3])])
	return out
