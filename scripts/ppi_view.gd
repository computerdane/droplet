class_name PpiView
extends Node2D
## 2D plan view: one sweep drawn by ppi.gdshader on a quad centred on the radar, with the
## basemap, range rings and city labels on top. World units are km, +x east, -y north.
## Wheel zooms, drag pans.

signal view_changed

const BASEMAP_SHADER := preload("res://shaders/basemap_2d.gdshader")
const PPI_SHADER := preload("res://shaders/ppi.gdshader")
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

var _dragging := false
var _cities: Array = []  # from Basemap.cities_near, most populous first
var _basemap_mats: Array[ShaderMaterial] = []
var _neighbor_rects: Array[ColorRect] = []

@onready var ppi: ColorRect = $PPI
@onready var cam: Camera2D = $Camera
@onready var overlay: Node2D = $Overlay
@onready var basemap_root: Node2D = $Basemap
@onready var neighbors_root: Node2D = $Neighbors


func _ready() -> void:
	overlay.draw.connect(_draw_overlay)
	_build_basemap()
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


## Centre the basemap and city labels on a radar site.
func set_site(lat: float, lon: float) -> void:
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
	_apply_sweep(ppi, vol, i, field_name, others)
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
		_apply_sweep(rect, n["volume"], n["sweep"], field_name, n["others"])


static func _apply_sweep(
	rect: ColorRect, vol: RadarVolume, i: int, field_name: String, others: PackedVector2Array
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
	_draw_cities()


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
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				_dragging = e.pressed
	elif event is InputEventMouseMotion and _dragging:
		cam.position -= (event as InputEventMouseMotion).relative / cam.zoom
		overlay.queue_redraw()
		view_changed.emit()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# Keep the world point under the cursor fixed.
	var off := screen_pos - get_viewport_rect().size / 2.0
	var before := off / cam.zoom.x
	set_zoom(cam.zoom.x * factor)
	cam.position += before - off / cam.zoom.x
	view_changed.emit()
