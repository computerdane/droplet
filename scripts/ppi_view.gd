class_name PpiView
extends Node2D
## 2D plan view: one sweep drawn by ppi.gdshader on a quad centred on the radar, with the
## basemap, range rings and city labels on top. World units are km, +x east, -y north.
## Wheel zooms, drag pans. In section mode a left drag draws the cross-section line A -> B
## instead (right or middle drag still pans).

signal view_changed
signal section_changed

const BASEMAP_SHADER := preload("res://shaders/basemap_2d.gdshader")
const PPI_SHADER := preload("res://shaders/ppi.gdshader")
const TRACKS_SHADER := preload("res://shaders/ppi_tracks.gdshader")
const ZOOM_STEP := 1.15
const ZOOM_MIN := 0.25
const ZOOM_MAX := 400.0
const DEFAULT_ZOOM := 1.6
const RING_STEP_KM := 50.0
const RING_MAX_KM := 450.0
const RING_COLOR := Color(1, 1, 1, 0.18)
const CITY_FONT_SIZE := 12
const CITY_COLOR := Color(0.95, 0.95, 1.0, 0.85)
const CITY_MAX_LABELS := 40
const CITY_RADIUS_KM := 600.0
const BASEMAP_CULL_KM := 6000.0
const SECTION_COLOR := Color(1, 1, 1, 0.95)

var storm_motion := Vector2.ZERO  # m/s east, north; zero = ground-relative (see main.gd)
var section_mode := false
var has_section := false
var section_a := Vector2.ZERO  # km, +x east, +y south (world = radar-local frame)
var section_b := Vector2.ZERO
var hover_marker := Vector2.INF  # point on the section line under the mouse in the panel
var _dragging := false
var _drawing_section := false
var _cities: Array = []  # from Basemap.cities_near, most populous first
var _basemap_mats: Array[ShaderMaterial] = []
var _site_latlon := Vector2.INF  # last set_site(), re-applied when the basemap arrives
var _neighbor_rects: Array[ColorRect] = []
var _ppi_material: ShaderMaterial  # the sweep material; show_tracks() swaps in another
var _tracks_material: ShaderMaterial
var _warnings: Array = []  # Warnings.project() output, drawn by the overlay

@onready var ppi: ColorRect = $PPI
@onready var cam: Camera2D = $Camera
@onready var overlay: Node2D = $Overlay
@onready var basemap_root: Node2D = $Basemap
@onready var neighbors_root: Node2D = $Neighbors


func _ready() -> void:
	_ppi_material = ppi.material
	overlay.draw.connect(_draw_overlay)
	Basemap.when_loaded(_on_basemap_loaded)
	reset_camera()


func _build_basemap() -> void:
	var bm := Basemap.get_shared()
	if bm == null:
		return
	for layer in Basemap.LAYER_STYLE:
		if not bm.meshes.has(layer):
			continue
		var mi := MeshInstance2D.new()
		mi.mesh = bm.meshes[layer]
		mi.modulate = Basemap.LAYER_STYLE[layer]
		var mat := ShaderMaterial.new()
		mat.shader = BASEMAP_SHADER
		mi.material = mat
		basemap_root.add_child(mi)
		# Vertices are lon/lat until the shader projects them, so the mesh's own rect is
		# useless for culling; give it the whole projected plane instead.
		var r := BASEMAP_CULL_KM
		RenderingServer.canvas_item_set_custom_rect(
			mi.get_canvas_item(), true, Rect2(-r, -r, 2 * r, 2 * r)
		)
		_basemap_mats.append(mat)


## Builds the basemap layers (possibly after a web download) and centres them on the site.
func _on_basemap_loaded() -> void:
	_build_basemap()
	if _site_latlon != Vector2.INF:
		set_site(_site_latlon.x, _site_latlon.y)


## Centre the basemap and city labels on a radar site.
func set_site(lat: float, lon: float) -> void:
	_site_latlon = Vector2(lat, lon)
	for mat in _basemap_mats:
		mat.set_shader_parameter("site_lonlat", Vector2(lon, lat))
	var bm := Basemap.get_shared()
	_cities = bm.cities_near(lat, lon, CITY_RADIUS_KM) if bm != null else []
	overlay.queue_redraw()


func set_active(on: bool) -> void:
	visible = on
	cam.enabled = on
	if on:
		cam.make_current()


func set_section(a: Vector2, b: Vector2) -> void:
	section_a = a
	section_b = b
	has_section = a != b
	overlay.queue_redraw()
	section_changed.emit()


## Marks the point of the section line that the mouse is over in the section panel;
## Vector2.INF clears it.
func set_hover_marker(p: Vector2) -> void:
	if p != hover_marker:
		hover_marker = p
		overlay.queue_redraw()


func set_section_mode(on: bool) -> void:
	section_mode = on
	_drawing_section = false
	overlay.queue_redraw()


func reset_camera() -> void:
	cam.position = Vector2.ZERO
	cam.zoom = Vector2(DEFAULT_ZOOM, DEFAULT_ZOOM)
	overlay.queue_redraw()
	view_changed.emit()


func zoom() -> float:
	return cam.zoom.x


func set_zoom(z: float) -> void:
	z = clampf(z, ZOOM_MIN, ZOOM_MAX)
	cam.zoom = Vector2(z, z)
	overlay.queue_redraw()


## Rotation tracks instead of a sweep: the maximum of the first `n_layers` layers of `tracks`
## (selected site only; mosaic neighbours are hidden). null blanks the display.
func show_tracks(tracks: RotationTracks, n_layers: int) -> void:
	for rect in _neighbor_rects:
		rect.get_parent().visible = false
	if tracks == null:
		ppi.visible = false
		return
	if _tracks_material == null:
		_tracks_material = ShaderMaterial.new()
		_tracks_material.shader = TRACKS_SHADER
	var mat := _tracks_material
	ppi.material = mat
	ppi.visible = true
	mat.set_shader_parameter("layers", tracks.texture)
	mat.set_shader_parameter("n_layers", clampi(n_layers, 0, tracks.names.size()))
	mat.set_shader_parameter("half_size", ppi.size.x / 2.0)
	mat.set_shader_parameter("first_gate_km", tracks.first_gate_km)
	mat.set_shader_parameter("gate_spacing_km", tracks.gate_spacing_km)
	mat.set_shader_parameter("n_gates", tracks.width)
	mat.set_shader_parameter("colormap", Colormaps.texture_for(RotationTracks.FIELD))
	var rng := Colormaps.range_of(RotationTracks.FIELD)
	mat.set_shader_parameter("cmap_min", rng[0])
	mat.set_shader_parameter("cmap_max", rng[1])
	mat.set_shader_parameter("min_value", RotationTracks.MIN_VALUE)


## Show sweep `i` of `vol` for `field_name`; pass i < 0 to blank the display.
## `neighbors` are mosaic entries from main.gd: {volume, sweep, offset_km (+y north),
## rotation, others}; `others` holds the other radars in each site's local frame so the
## shader can keep only the pixels nearest to its own radar.
func show_sweep(
	vol: RadarVolume,
	i: int,
	field_name: String,
	neighbors: Array = [],
	others := PackedVector2Array()
) -> void:
	ppi.material = _ppi_material
	_apply_sweep(ppi, vol, i, field_name, others, storm_motion)
	while _neighbor_rects.size() < neighbors.size():
		var holder := Node2D.new()
		neighbors_root.add_child(holder)
		var rect := ColorRect.new()
		rect.position = ppi.position
		rect.size = ppi.size
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		rect.material = ShaderMaterial.new()
		(rect.material as ShaderMaterial).shader = PPI_SHADER
		holder.add_child(rect)
		_neighbor_rects.append(rect)
	for k in _neighbor_rects.size():
		var rect := _neighbor_rects[k]
		var holder := rect.get_parent() as Node2D
		if k >= neighbors.size():
			holder.visible = false
			continue
		var n: Dictionary = neighbors[k]
		var off: Vector2 = n["offset_km"]
		holder.position = Vector2(off.x, -off.y)
		holder.rotation = n["rotation"]
		holder.visible = true
		var storm := storm_motion.rotated(n["rotation"])  # into the neighbour's frame
		_apply_sweep(rect, n["volume"], n["sweep"], field_name, n["others"], storm)


static func _apply_sweep(
	rect: ColorRect,
	vol: RadarVolume,
	i: int,
	field_name: String,
	others: PackedVector2Array,
	storm: Vector2
) -> void:
	if vol == null or i < 0:
		rect.visible = false
		return
	var mat := rect.material as ShaderMaterial
	mat.set_shader_parameter("other_sites", others)
	mat.set_shader_parameter("n_other_sites", others.size())
	var f: Dictionary = vol.sweep(i)["fields"][field_name]
	mat.set_shader_parameter("sweep", vol.get_texture(i, field_name))
	mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
	var rng := Colormaps.range_of(field_name)
	mat.set_shader_parameter("cmap_min", rng[0])
	mat.set_shader_parameter("cmap_max", rng[1])
	mat.set_shader_parameter("first_gate_km", float(f["first_gate_m"]) / 1000.0)
	mat.set_shader_parameter("gate_spacing_km", float(f["gate_spacing_m"]) / 1000.0)
	mat.set_shader_parameter("n_gates", int(f["n_gates"]))
	mat.set_shader_parameter("elevation_deg", vol.elevation(i))
	mat.set_shader_parameter("storm_motion", storm)
	mat.set_shader_parameter("half_size", rect.size.x / 2.0)
	rect.visible = true


func _draw_overlay() -> void:
	var r := RING_STEP_KM
	while r <= RING_MAX_KM:
		overlay.draw_arc(Vector2.ZERO, r, 0.0, TAU, 256, RING_COLOR, -1.0)
		r += RING_STEP_KM
	var s := 4.0 / cam.zoom.x  # ~4 px cross at the radar
	overlay.draw_line(Vector2(-s, 0), Vector2(s, 0), Color.WHITE, -1.0)
	overlay.draw_line(Vector2(0, -s), Vector2(0, s), Color.WHITE, -1.0)
	_draw_warnings()
	_draw_cities()
	if section_mode and has_section:
		_draw_section_line()


func _draw_section_line() -> void:
	var z := cam.zoom.x
	overlay.draw_line(section_a, section_b, Color(0, 0, 0, 0.6), 4.0 / z)
	overlay.draw_line(section_a, section_b, SECTION_COLOR, 2.0 / z)
	var font := ThemeDB.fallback_font
	for end in [[section_a, "A"], [section_b, "B"]]:
		overlay.draw_set_transform(end[0], 0.0, Vector2.ONE / z)
		overlay.draw_circle(Vector2.ZERO, 4.0, SECTION_COLOR)
		overlay.draw_string_outline(
			font, Vector2(7, -6), end[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, 4, Color.BLACK
		)
		overlay.draw_string(
			font, Vector2(7, -6), end[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, SECTION_COLOR
		)
	if hover_marker != Vector2.INF:
		overlay.draw_set_transform(hover_marker, 0.0, Vector2.ONE / z)
		overlay.draw_arc(Vector2.ZERO, 6.0, 0.0, TAU, 24, Color.BLACK, 4.0, true)
		overlay.draw_arc(Vector2.ZERO, 6.0, 0.0, TAU, 24, Color.YELLOW, 2.0, true)
	overlay.draw_set_transform(Vector2.ZERO)


## Warning polygons (Warnings.project()), outlined at a constant screen width.
func set_warnings(polys: Array) -> void:
	_warnings = polys
	overlay.queue_redraw()


func _draw_warnings() -> void:
	var z := cam.zoom.x
	for w in _warnings:
		for ring: PackedVector2Array in w["rings"]:
			overlay.draw_polyline(ring, Color(0, 0, 0, 0.7), 4.0 / z)
			overlay.draw_polyline(ring, w["color"], 2.0 / z)


## City dots and names at constant screen size; greedy declutter, biggest cities first.
func _draw_cities() -> void:
	var font := ThemeDB.fallback_font
	var z := cam.zoom.x
	var half := get_viewport_rect().size / 2.0
	var placed: Array[Rect2] = []
	for c in _cities:
		if placed.size() >= CITY_MAX_LABELS:
			break
		var world := Vector2(c[1].x, -c[1].y)
		var screen: Vector2 = (world - cam.position) * z + half
		var text_size := font.get_string_size(c[0], HORIZONTAL_ALIGNMENT_LEFT, -1, CITY_FONT_SIZE)
		var box := Rect2(screen + Vector2(-3, -text_size.y), text_size + Vector2(10, 4))
		if not get_viewport_rect().intersects(box):
			continue
		var clear := true
		for other in placed:
			if other.intersects(box):
				clear = false
				break
		if not clear:
			continue
		placed.append(box)
		overlay.draw_set_transform(world, 0.0, Vector2.ONE / z)
		overlay.draw_circle(Vector2.ZERO, 2.0, CITY_COLOR)
		overlay.draw_string_outline(
			font,
			Vector2(5, -3),
			c[0],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			CITY_FONT_SIZE,
			3,
			Color(0, 0, 0, 0.7)
		)
		overlay.draw_string(
			font, Vector2(5, -3), c[0], HORIZONTAL_ALIGNMENT_LEFT, -1, CITY_FONT_SIZE, CITY_COLOR
		)
	overlay.draw_set_transform(Vector2.ZERO)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseButton:
		var e := event as InputEventMouseButton
		match e.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if e.pressed:
					_zoom_at(e.position, ZOOM_STEP)
			MOUSE_BUTTON_WHEEL_DOWN:
				if e.pressed:
					_zoom_at(e.position, 1.0 / ZOOM_STEP)
			MOUSE_BUTTON_LEFT when section_mode:
				_drawing_section = e.pressed
				if e.pressed:
					set_section(_to_world(e.position), _to_world(e.position))
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = e.pressed
	elif event is InputEventMouseMotion and _drawing_section:
		set_section(section_a, _to_world((event as InputEventMouseMotion).position))
	elif event is InputEventMouseMotion and _dragging:
		cam.position -= (event as InputEventMouseMotion).relative / cam.zoom
		overlay.queue_redraw()
		view_changed.emit()


func _to_world(screen_pos: Vector2) -> Vector2:
	return cam.position + (screen_pos - get_viewport_rect().size / 2.0) / cam.zoom.x


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# Keep the world point under the cursor fixed.
	var off := screen_pos - get_viewport_rect().size / 2.0
	var before := off / cam.zoom.x
	set_zoom(cam.zoom.x * factor)
	cam.position += before - off / cam.zoom.x
	view_changed.emit()
