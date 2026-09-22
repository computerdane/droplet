class_name Basemap
extends RefCounted
## Loads data/basemap (built by `nexrad basemap`): line layers as lon/lat meshes
## that basemap_2d/3d.gdshader project around the site on the GPU, and a city list.
## Loaded once and shared; `basemap=0` turns it off, `basemap=<dir>` (a URL on web) reads another
## copy. On web it is downloaded in the background from WEB_URL, so views use when_loaded().

const DEFAULT_ROOT := "res://data/basemap"
## Web: where the page fetches the basemap from, relative to index.html (web/build.sh).
const WEB_URL := "basemap"
const EARTH_RADIUS_KM := 6371.0
## Draw order and style; later layers draw on top.
const LAYER_STYLE := {
	"counties": Color(0.75, 0.8, 0.9, 0.16),
	"states": Color(0.85, 0.9, 1.0, 0.55),
}

static var _shared: Basemap
static var _tried := false
static var _waiting: Array[Callable] = []
static var _js_done: JavaScriptObject  # web: keeps the fetch callback alive

var meshes: Dictionary = {}  # layer -> ArrayMesh (PRIMITIVE_LINES, Vector2 lon/lat vertices)
var cities: Array = []  # [name, lat, lon, population], most populous first


## The basemap, or null while it is loading (web), missing or turned off. Views build theirs in
## a when_loaded() callback instead, so a basemap that arrives late still shows up.
static func get_shared() -> Basemap:
	_start_loading()
	return _shared


## Calls `fn` once the basemap is available: now on the desktop (the files are local), when
## the download finishes on web. Never called if there is none.
static func when_loaded(fn: Callable) -> void:
	_start_loading()
	if _shared != null:
		fn.call()
	else:
		_waiting.append(fn)


static func _start_loading() -> void:
	if _tried:
		return
	_tried = true
	var root: String = AppOptions.parse().get("basemap", DEFAULT_ROOT)
	if root == "0":
		return
	if OS.has_feature("web"):
		_fetch_web(WEB_URL if root == DEFAULT_ROOT else root)
	else:
		_loaded(load_from_dir(root))


static func _loaded(bm: Basemap) -> void:
	_shared = bm
	if bm == null:
		_waiting.clear()
		return
	for fn in _waiting:
		if fn.is_valid():
			fn.call()
	_waiting.clear()


## Web: res://data is not exported; the page fetches basemap.json and its layers from `url`
## (web/build.sh copies data/basemap next to index.html), then hands the bytes over.
static func _fetch_web(url: String) -> void:
	var window := JavaScriptBridge.get_interface("window")
	_js_done = JavaScriptBridge.create_callback(_on_web_fetched)
	window.droplet_basemap_done = _js_done
	(
		JavaScriptBridge
		. eval(
			(
				"""
		(async (base) => {
			try {
				const get = async (f) => {
					const r = await fetch(base + f);
					if (!r.ok) throw new Error(f + ': HTTP ' + r.status);
					return r;
				};
				const meta = await (await get('basemap.json')).text();
				const layers = JSON.parse(meta).layers;
				const names = Object.values(layers).map((l) => l.file);
				const buffers = await Promise.all(names.map(async (f) => (await get(f)).arrayBuffer()));
				self.droplet_basemap = {meta, names, buffers};
				self.droplet_basemap_done(true);
			} catch (e) {
				console.warn('basemap not loaded:', e.message);
				self.droplet_basemap_done(false);
			}
		})(%s)
		"""
				% JSON.stringify(url.trim_suffix("/") + "/")
			),
			true
		)
	)


static func _on_web_fetched(args: Array) -> void:
	if not args[0]:
		_loaded(null)
		return
	var js: JavaScriptObject = JavaScriptBridge.get_interface("window").droplet_basemap
	var files := {}
	for i in int(js.names.length):
		files[str(js.names[i])] = JavaScriptBridge.js_buffer_to_packed_byte_array(js.buffers[i])
	JavaScriptBridge.eval("delete self.droplet_basemap", true)
	_loaded(
		from_files(
			str(js.meta), func(f: String) -> PackedByteArray: return files.get(f, PackedByteArray())
		)
	)


static func load_from_dir(dir: String) -> Basemap:
	return from_files(
		FileAccess.get_file_as_string(dir.path_join("basemap.json")),
		func(f: String) -> PackedByteArray: return FileAccess.get_file_as_bytes(dir.path_join(f))
	)


## `read` maps a layer file name to its bytes.
static func from_files(text: String, read: Callable) -> Basemap:
	if text.is_empty():
		return null
	var meta = JSON.parse_string(text)
	if not meta is Dictionary:
		push_error("Basemap: bad basemap.json")
		return null
	var bm := Basemap.new()
	bm.cities = meta.get("cities", [])
	for layer in LAYER_STYLE:
		var info: Dictionary = meta["layers"].get(layer, {})
		if info.is_empty():
			continue
		var mesh := _load_layer(info["file"], read.call(info["file"]))
		if mesh != null:
			bm.meshes[layer] = mesh
	return bm


static func _load_layer(path: String, bytes: PackedByteArray) -> ArrayMesh:
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


## Inverse of project(): [lat, lon] in degrees of the point `p` km from the site
## (+x east, +y north).
static func unproject(p: Vector2, site_lat: float, site_lon: float) -> Vector2:
	var lat0 := deg_to_rad(site_lat)
	var c := p.length() / EARTH_RADIUS_KM
	var bearing := atan2(p.x, p.y)
	var lat := asin(clampf(sin(lat0) * cos(c) + cos(lat0) * sin(c) * cos(bearing), -1.0, 1.0))
	var dlon := atan2(sin(bearing) * sin(c) * cos(lat0), cos(c) - sin(lat0) * sin(lat))
	return Vector2(rad_to_deg(lat), site_lon + rad_to_deg(dlon))


## Cities within `radius_km` of the site as [name, Vector2 km (+y north), population].
func cities_near(site_lat: float, site_lon: float, radius_km: float) -> Array:
	var out := []
	for c in cities:
		var p := project(c[1], c[2], site_lat, site_lon)
		if p.length() <= radius_km:
			out.append([c[0], p, int(c[3])])
	return out
