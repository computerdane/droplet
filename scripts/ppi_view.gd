class_name PpiView
extends Node2D
## 2D plan view: one sweep drawn by ppi.gdshader on a quad centred on the radar, with the
## basemap, range rings and city labels on top. World units are km, +x east, -y north.
## Wheel zooms, drag pans. In section mode a left drag draws the cross-section line A -> B
## instead (right or middle drag still pans).

signal view_changed
signal section_changed
signal site_clicked(site: String)

const BASEMAP_SHADER := preload("res://shaders/basemap_2d.gdshader")
const PPI_SHADER := preload("res://shaders/ppi.gdshader")
const TRACKS_SHADER := preload("res://shaders/ppi_tracks.gdshader")
const ZOOM_STEP := 1.15
const ZOOM_MIN := 0.05
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
const CELL_FORECAST_COLOR := Color(0.55, 0.85, 1.0, 0.9)
const SITE_COLOR := Color(0.6, 0.85, 1.0, 0.9)
const SITE_ACTIVE_COLOR := Color(1.0, 0.75, 0.2, 1.0)
const SITE_MARKER_RADIUS_PX := 3.5
const SITE_HIT_RADIUS_PX := 12.0
const SITE_LABEL_ZOOM := 0.5  # show ICAO labels only zoomed in this far or more
const SITE_CLICK_MOVE_PX := 6.0  # press/release must stay within this to count as a click
const DEFAULT_CENTER_LATLON := Vector2(39.0, -98.0)  # CONUS, used before any set_site()

var storm_motion := Vector2.ZERO  # m/s east, north; zero = ground-relative (see main.gd)
var section_mode := false
var has_section := false
var section_a := Vector2.ZERO  # km, +x east, +y south (world = radar-local frame)
var section_b := Vector2.ZERO
var hover_marker := Vector2.INF  # point on the section line under the mouse in the panel
var _dragging := false
var _touch := TouchGestures.new()
var _drawing_section := false
var _cities: Array = []  # from Basemap.cities_near, most populous first
var _basemap_mats: Array[ShaderMaterial] = []
var _site_latlon := Vector2.INF  # last set_site(), re-applied when the basemap arrives
var _neighbor_rects: Array[ColorRect] = []
var _ppi_material: ShaderMaterial  # the sweep material; show_tracks() swaps in another
var _tracks_material: ShaderMaterial
var _warnings: Array = []  # Warnings.project() output, drawn by the overlay
var _outlook: Array = []  # the SPC outlook's areas, the same shape
var _cells: Array = []  # StormCells.track() entries of the frame on screen
var _sites: Array[String] = []  # RadarSites codes shown as clickable station markers
var _site_positions: Dictionary = {}  # code -> Vector2 km, camera/world frame (+x east, +y south)
var _press_screen := Vector2.INF  # left-button-down screen pos; used to tell a click from a drag

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
	_rebuild_site_positions()
	overlay.queue_redraw()


## Station markers to draw and hit-test, e.g. RadarSites.ids() for every known US NEXRAD site.
## Shown at national zoom and centred on any site; unknown codes are skipped. Safe to call
## before set_site() (positions are projected around DEFAULT_CENTER_LATLON until it is).
func set_sites(sites: Array[String]) -> void:
	_sites = sites
	_rebuild_site_positions()
	overlay.queue_redraw()


func _center_latlon() -> Vector2:
	return _site_latlon if _site_latlon != Vector2.INF else DEFAULT_CENTER_LATLON


func _rebuild_site_positions() -> void:
	_site_positions.clear()
	var center := _center_latlon()
	for code in _sites:
		var ll := RadarSites.location(code)
		if ll == Vector2.INF:
			continue
		var p := Basemap.project(ll.x, ll.y, center.x, center.y)  # +x east, +y north
		_site_positions[code] = Vector2(p.x, -p.y)  # into camera/world frame (+y south)


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


## Rotation tracks instead of a sweep: the maximum of the first `n_layers` layers of `tracks`.
## Mosaic `neighbors` (as show_sweep takes them) show theirs where they carry "tracks" and
## "n_tracks" (main._update_neighbor_tracks); null blanks the display.
func show_tracks(
	tracks: RotationTracks, n_layers: int, neighbors: Array = [], others := PackedVector2Array()
) -> void:
	if _tracks_material == null:
		_tracks_material = _new_tracks_material()
	ppi.material = _tracks_material
	_apply_tracks(ppi, tracks, n_layers, others)
	_ensure_neighbor_rects(neighbors.size())
	for k in _neighbor_rects.size():
		var rect := _neighbor_rects[k]
		var holder := rect.get_parent() as Node2D
		var n: Dictionary = neighbors[k] if k < neighbors.size() else {}
		if n.get("tracks") == null:
			holder.visible = false
			continue
		_place(holder, n)
		rect.material = rect.get_meta("tracks")
		_apply_tracks(rect, n["tracks"], n["n_tracks"], n["others"])


static func _new_tracks_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = TRACKS_SHADER
	return mat


static func _apply_tracks(
	rect: ColorRect, tracks: RotationTracks, n_layers: int, others: PackedVector2Array
) -> void:
	if tracks == null:
		rect.visible = false
		return
	rect.visible = true
	var mat := rect.material as ShaderMaterial
	mat.set_shader_parameter("layers", tracks.texture)
	mat.set_shader_parameter("n_layers", clampi(n_layers, 0, tracks.names.size()))
	mat.set_shader_parameter("half_size", rect.size.x / 2.0)
	mat.set_shader_parameter("first_gate_km", tracks.first_gate_km)
	mat.set_shader_parameter("gate_spacing_km", tracks.gate_spacing_km)
	mat.set_shader_parameter("n_gates", tracks.width)
	mat.set_shader_parameter("colormap", Colormaps.texture_for(RotationTracks.FIELD))
	var rng := Colormaps.range_of(RotationTracks.FIELD)
	mat.set_shader_parameter("cmap_min", rng[0])
	mat.set_shader_parameter("cmap_max", rng[1])
	mat.set_shader_parameter("min_value", RotationTracks.MIN_VALUE)
	mat.set_shader_parameter("other_sites", others)
	mat.set_shader_parameter("n_other_sites", others.size())


## One ColorRect (in a Node2D holder placed at the site) per mosaic neighbour, each with a
## sweep material and a rotation tracks one (metadata "ppi" / "tracks").
func _ensure_neighbor_rects(n: int) -> void:
	while _neighbor_rects.size() < n:
		var holder := Node2D.new()
		neighbors_root.add_child(holder)
		var rect := ColorRect.new()
		rect.position = ppi.position
		rect.size = ppi.size
		rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mat := ShaderMaterial.new()
		mat.shader = PPI_SHADER
		rect.set_meta("ppi", mat)
		rect.set_meta("tracks", _new_tracks_material())
		holder.add_child(rect)
		_neighbor_rects.append(rect)


static func _place(holder: Node2D, n: Dictionary) -> void:
	var off: Vector2 = n["offset_km"]
	holder.position = Vector2(off.x, -off.y)
	holder.rotation = n["rotation"]
	holder.visible = true


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
	_ensure_neighbor_rects(neighbors.size())
	for k in _neighbor_rects.size():
		var rect := _neighbor_rects[k]
		var holder := rect.get_parent() as Node2D
		if k >= neighbors.size():
			holder.visible = false
			continue
		var n: Dictionary = neighbors[k]
		_place(holder, n)
		rect.material = rect.get_meta("ppi")
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
	_draw_cells()
	_draw_site_markers()
	_draw_cities()
	if section_mode and has_section:
		_draw_section_line()


## All known NEXRAD stations as small clickable dots at constant screen size; the site
## currently on screen (world origin) is highlighted, and codes label themselves once zoomed
## in enough to read.
func _draw_site_markers() -> void:
	var z := cam.zoom.x
	var font := ThemeDB.fallback_font
	var show_labels := z >= SITE_LABEL_ZOOM
	for code in _site_positions:
		var p: Vector2 = _site_positions[code]
		var active := p.length() < 0.5  # ~on top of the radar currently shown
		var color := SITE_ACTIVE_COLOR if active else SITE_COLOR
		var radius := (SITE_MARKER_RADIUS_PX + 1.5 if active else SITE_MARKER_RADIUS_PX) / z
		overlay.draw_circle(p, radius + 1.0 / z, Color(0, 0, 0, 0.65))
		overlay.draw_circle(p, radius, color)
		if show_labels:
			overlay.draw_set_transform(p, 0.0, Vector2.ONE / z)
			overlay.draw_string_outline(
				font,
				Vector2(6, -4),
				code,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1,
				12,
				3,
				Color(0, 0, 0, 0.7)
			)
			overlay.draw_string(
				font, Vector2(6, -4), code, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color
			)
			overlay.draw_set_transform(Vector2.ZERO)


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


## Tracked storm cells (StormCells.track()) to draw: past track, forecast and a marker ringed
## by its rotation.
func set_cells(cells: Array) -> void:
	_cells = cells
	overlay.queue_redraw()


func _draw_cells() -> void:
	var z := cam.zoom.x
	var shadow := Color(0, 0, 0, 0.7)
	for c in _cells:
		var pos := Vector2(c["pos"].x, -c["pos"].y)
		var past := PackedVector2Array()
		for p in c["track"]:
			past.append(Vector2(p.x, -p.y))
		if past.size() > 1:
			overlay.draw_polyline(past, shadow, 3.0 / z)
			overlay.draw_polyline(past, Color(1, 1, 1, 0.75), 1.5 / z)
		for p in past.slice(0, past.size() - 1):
			overlay.draw_circle(p, 2.0 / z, Color(1, 1, 1, 0.75))
		var ahead := StormCells.forecast(c)
		if not ahead.is_empty():
			var end := Vector2(ahead[-1].x, -ahead[-1].y)
			overlay.draw_line(pos, end, shadow, 3.0 / z)
			overlay.draw_line(pos, end, CELL_FORECAST_COLOR, 1.5 / z)
			for p in ahead:
				overlay.draw_arc(
					Vector2(p.x, -p.y), 3.0 / z, 0.0, TAU, 12, CELL_FORECAST_COLOR, 1.5 / z
				)
		var rot := float(c["rot"])
		if c["tds"]:
			var s := 9.0 / z
			var tri := PackedVector2Array(
				[pos + Vector2(0, -s), pos + Vector2(s, s * 0.7), pos + Vector2(-s, s * 0.7)]
			)
			overlay.draw_colored_polygon(tri, Color(1, 0.1, 0.8))
		elif rot >= StormCells.ROT_MESO:
			var col := Color(1, 0.15, 0.15) if rot >= StormCells.ROT_STRONG else Color(1, 0.85, 0)
			overlay.draw_arc(pos, 8.0 / z, 0.0, TAU, 24, shadow, 5.0 / z)
			overlay.draw_arc(pos, 8.0 / z, 0.0, TAU, 24, col, 2.5 / z)
		overlay.draw_circle(pos, 3.5 / z, shadow)
		overlay.draw_circle(pos, 2.5 / z, Color.WHITE)


## Warning polygons and SPC outlook areas (Warnings.project()), outlined at a constant screen
## width; the outlook dashed and under the warnings.
func set_warnings(polys: Array, outlook: Array = []) -> void:
	_warnings = polys
	_outlook = outlook
	overlay.queue_redraw()


func _draw_warnings() -> void:
	var z := cam.zoom.x
	for area in _outlook:
		var color: Color = area["color"]
		for ring: PackedVector2Array in area["rings"]:
			overlay.draw_polyline(ring, Color(0, 0, 0, 0.5), 3.5 / z)
			for i in ring.size() - 1:
				overlay.draw_dashed_line(ring[i], ring[i + 1], color, 1.5 / z, 6.0 / z, false)
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
	var g := _touch.feed(event)
	if not g.is_empty():
		_zoom_at(g["center"], g["zoom"])
		_pan_by(g["pan"])
	elif event is InputEventMagnifyGesture:  # trackpad pinch
		_zoom_at(event.position, (event as InputEventMagnifyGesture).factor)
	elif _touch.active() and (event is InputEventMouseMotion or event is InputEventMouseButton):
		pass  # the first finger of a pinch, as emulated mouse
	elif event is InputEventMouseButton:
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
				if e.button_index == MOUSE_BUTTON_LEFT:
					if e.pressed:
						_press_screen = e.position
					else:
						if (
							_press_screen != Vector2.INF
							and e.position.distance_to(_press_screen) <= SITE_CLICK_MOVE_PX
						):
							_try_click_site(e.position)
						_press_screen = Vector2.INF
	elif event is InputEventMouseMotion and _drawing_section:
		set_section(section_a, _to_world((event as InputEventMouseMotion).position))
	elif event is InputEventMouseMotion and _dragging:
		_pan_by((event as InputEventMouseMotion).relative)


func _pan_by(screen_delta: Vector2) -> void:
	cam.position -= screen_delta / cam.zoom
	overlay.queue_redraw()
	view_changed.emit()


func _to_world(screen_pos: Vector2) -> Vector2:
	return cam.position + (screen_pos - get_viewport_rect().size / 2.0) / cam.zoom.x


## The nearest station within a constant screen-space radius, or an empty code. Shared by
## hover feedback and click selection so they always agree at dense national zoom.
func station_at(screen_pos: Vector2) -> String:
	var world := _to_world(screen_pos)
	var hit_r := SITE_HIT_RADIUS_PX / cam.zoom.x
	var best_code := ""
	var best_dist := INF
	for code in _site_positions:
		var d: float = (_site_positions[code] as Vector2).distance_to(world)
		if d <= hit_r and d < best_dist:
			best_dist = d
			best_code = code
	return best_code


func _try_click_site(screen_pos: Vector2) -> void:
	var code := station_at(screen_pos)
	if not code.is_empty():
		site_clicked.emit(code)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	# Keep the world point under the cursor fixed.
	var off := screen_pos - get_viewport_rect().size / 2.0
	var before := off / cam.zoom.x
	set_zoom(cam.zoom.x * factor)
	cam.position += before - off / cam.zoom.x
	view_changed.emit()
