class_name NationalComposite
extends MeshInstance2D
## NOAA MRMS quality-controlled composite reflectivity, projected onto the same
## azimuthal-equidistant plane as the US basemap. The image is live, not a radar volume.

const CENTER := Vector2(39.0, -98.0)  # latitude, longitude
const WEST := -126.0
const SOUTH := 23.0
const EAST := -66.0
const NORTH := 51.0
const WIDTH := 1200
const HEIGHT := 560
const GRID_X := 40
const GRID_Y := 24
const REFRESH_SEC := 300.0
const WMS_URL := (
	"https://opengeo.ncep.noaa.gov/geoserver/conus/conus_cref_qcd/ows"
	+ "?service=WMS&version=1.1.1&request=GetMap&layers=conus_cref_qcd"
	+ "&styles=&srs=EPSG:4326&bbox=-126,23,-66,51&width=1200&height=560"
	+ "&format=image/png&transparent=true"
)

var _request: HTTPRequest
var _timer: Timer


func _ready() -> void:
	mesh = _build_mesh()
	_request = HTTPRequest.new()
	add_child(_request)
	_request.request_completed.connect(_on_image)
	_timer = Timer.new()
	_timer.wait_time = REFRESH_SEC
	_timer.timeout.connect(_load)
	add_child(_timer)
	if visible:
		_load()
		_timer.start()


func set_overview(on: bool) -> void:
	visible = on
	if _timer == null:
		return
	if on:
		_load()  # returning to the map should not show an hours-old image
		_timer.start()
	else:
		_timer.stop()
		_request.cancel_request()


func _load() -> void:
	if _request.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var err := _request.request(
		WMS_URL + "&t=" + str(int(Time.get_unix_time_from_system() / REFRESH_SEC))
	)
	if err != OK:
		push_warning("NOAA composite request failed: %s" % error_string(err))


func _on_image(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		push_warning("NOAA composite unavailable (result %d, HTTP %d)" % [result, code])
		return
	var image := Image.new()
	var err := image.load_png_from_buffer(body)
	if err != OK:
		push_warning("NOAA composite was not a PNG: %s" % error_string(err))
		return
	texture = ImageTexture.create_from_image(image)


static func _build_mesh() -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	for y in GRID_Y + 1:
		var v := float(y) / GRID_Y
		var lat := lerpf(NORTH, SOUTH, v)
		for x in GRID_X + 1:
			var u := float(x) / GRID_X
			var lon := lerpf(WEST, EAST, u)
			var p := Basemap.project(lat, lon, CENTER.x, CENTER.y)
			vertices.append(Vector2(p.x, -p.y))
			uvs.append(Vector2(u, v))
	var indices := PackedInt32Array()
	for y in GRID_Y:
		for x in GRID_X:
			var a := y * (GRID_X + 1) + x
			var b := a + GRID_X + 1
			indices.append_array(PackedInt32Array([a, b, a + 1, a + 1, b, b + 1]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out
