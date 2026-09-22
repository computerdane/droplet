class_name VolumeView3D
extends Node3D
## 3D volume view: every tilt of one field as a cone (cone.gdshader), or with
## `volume_render` as a translucent ray-marched volume (VolumeRender), over a ground disk
## with basemap lines, city labels, range rings and a height scale at the radar.
## Heights are exaggerated for legibility.

const GROUND_RADIUS_KM := 480.0
const MOSAIC_FADE_KM := 1000.0
const RING_STEP_KM := 50.0
const HEIGHT_TICK_KM := 5.0
const HEIGHT_MAX_KM := 20.0
const DEFAULT_EXAGGERATION := 4.0
const EXAGGERATION_MIN := 1.0
const EXAGGERATION_MAX := 20.0
const CITY_RADIUS_KM := 350.0
const CITY_MAX_LABELS := 24
const ISOLATE_NAMES := ["all tilts", "selected and below", "selected only"]
const DEFAULT_DENSITY := 0.05  # volume render opacity per km at full strength
const DENSITY_STEP := 1.5
const BASEMAP_SHADER := preload("res://shaders/basemap_3d.gdshader")

## Default display thresholds for 3D (drawing everything hides the storm inside clear air).
## [value, use |value|]
const DEFAULT_THRESHOLDS := {
	"REF": [15.0, false],
	"VEL": [10.0, true],
	"SW": [2.0, false],
	"ZDR": [-10.0, false],
	"PHI": [-10.0, false],
	"RHO": [0.8, false],
	"CFP": [-10.0, false],
	"DVEL": [10.0, true],
	"KDP": [0.5, false],
	"AZSHR": [4.0, true],
}

var storm_motion := Vector2.ZERO  # m/s east, north in the selected site's frame; zero = off
var exaggeration := DEFAULT_EXAGGERATION
var isolate := ConeSet.Isolate.ALL
var volume_render := false
var density := DEFAULT_DENSITY
var thresholds: Dictionary = {}  # field -> float; overrides DEFAULT_THRESHOLDS
var overlay := Overlay3D.new()  # section curtain, warnings, cells
var _neighbors: Array[ConeSet] = []
var _renders: Array[VolumeRender] = []  # selected site first, then mosaic neighbours
var _height_lines: MeshInstance3D  # built in true km, scaled on y by exaggeration
var _height_labels: Array[Label3D] = []
var _basemap_mats: Array[ShaderMaterial] = []
var _site_latlon := Vector2.INF  # last set_site(), re-applied when the basemap arrives
var _city_labels: Array[Label3D] = []

@onready var camera: OrbitCamera = $Camera
@onready var cones: ConeSet = $Cones


func _ready() -> void:
	_build_ground()
	overlay.exaggeration = exaggeration
	add_child(overlay)
	Basemap.when_loaded(_on_basemap_loaded)
	_build_height_scale()


func set_active(on: bool) -> void:
	visible = on
	camera.current = on


func threshold_of(field_name: String) -> float:
	return thresholds.get(field_name, DEFAULT_THRESHOLDS.get(field_name, [-10000.0])[0])


func threshold_is_abs(field_name: String) -> bool:
	return DEFAULT_THRESHOLDS.get(field_name, [0.0, false])[1]


func adjust_threshold(field_name: String, steps: int) -> void:
	var rng := Colormaps.range_of(field_name)
	var step: float = (rng[1] - rng[0]) / 22.0
	var t := threshold_of(field_name)
	var lo: float = 0.0 if threshold_is_abs(field_name) else rng[0] - step
	thresholds[field_name] = clampf(snappedf(t + steps * step, 0.01), lo, rng[1])


func set_exaggeration(v: float) -> void:
	exaggeration = clampf(v, EXAGGERATION_MIN, EXAGGERATION_MAX)
	_place_height_scale()
	cones.set_exaggeration(exaggeration)
	overlay.set_exaggeration(exaggeration)
	for n in _neighbors:
		n.set_exaggeration(exaggeration)
	for vr in _renders:
		vr.set_exaggeration(exaggeration)


func adjust_density(steps: int) -> void:
	density = clampf(density * pow(DENSITY_STEP, steps), 0.002, 2.0)


## Draw all tilts of `field_name`, honouring the isolate mode relative to `sel_elev`.
## `neighbors` are mosaic entries from main.gd: {volume, offset_km (+y north), rotation,
## others}; `others` is the other radars in the selected site's frame (see ConeSet).
func show_volume(
	vol: RadarVolume,
	field_name: String,
	sel_elev: float,
	neighbors: Array = [],
	others := PackedVector2Array()
) -> void:
	var thr := threshold_of(field_name)
	var abs_mode := threshold_is_abs(field_name)
	if volume_render:
		cones.visible = false
		for cs in _neighbors:
			cs.visible = false
		_show_renders(vol, field_name, thr, abs_mode, neighbors, others)
		for mat in _basemap_mats:
			mat.set_shader_parameter("fade_km", MOSAIC_FADE_KM if neighbors else GROUND_RADIUS_KM)
		return
	for vr in _renders:
		vr.visible = false
	cones.visible = true
	cones.storm_motion = storm_motion
	cones.show_volume(vol, field_name, sel_elev, isolate, thr, abs_mode, exaggeration, others)
	while _neighbors.size() < neighbors.size():
		var cs := ConeSet.new()
		add_child(cs)
		_neighbors.append(cs)
	for k in _neighbors.size():
		var cs := _neighbors[k]
		cs.visible = k < neighbors.size()
		if not cs.visible:
			continue
		var n: Dictionary = neighbors[k]
		var off: Vector2 = n["offset_km"]
		cs.position = Vector3(off.x, 0, -off.y)
		cs.rotation = Vector3(0, -float(n["rotation"]), 0)
		cs.storm_motion = storm_motion.rotated(n["rotation"])
		cs.show_volume(
			n["volume"], field_name, sel_elev, isolate, thr, abs_mode, exaggeration, n["others"]
		)
	for mat in _basemap_mats:
		mat.set_shader_parameter("fade_km", MOSAIC_FADE_KM if neighbors else GROUND_RADIUS_KM)


## What is under screen point `screen` (viewport pixels): the nearest drawn cone of any
## radar (ConeSet.pick, plus "site_offset" and "rotation" of that radar in the selected site's
## frame), else {"ground": Vector2 km east, north} where the ray meets the ground, else {}.
func pick(screen: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen)
	var dir := camera.project_ray_normal(screen)
	var max_t := camera.distance * 2.0 + 2.0 * GROUND_RADIUS_KM
	var step := clampf(camera.distance / 500.0, 0.05, 1.0)
	var best := {}
	var sets: Array[ConeSet] = [cones]
	sets.append_array(_neighbors)
	for cs in sets:
		var to_local := cs.global_transform.affine_inverse()
		var hit := cs.pick(to_local * origin, (to_local.basis * dir).normalized(), max_t, step)
		if not hit.is_empty() and (best.is_empty() or hit["t"] < best["t"]):
			hit["site_offset"] = Vector2(cs.position.x, -cs.position.z)
			hit["rotation"] = -cs.rotation.y
			best = hit
	if best.is_empty() and dir.y < -1e-4:
		var g := origin + dir * (-origin.y / dir.y)
		if Vector2(g.x, g.z).length() < MOSAIC_FADE_KM:
			best = {"ground": Vector2(g.x, -g.z)}
	return best


func _show_renders(
	vol: RadarVolume,
	field_name: String,
	thr: float,
	abs_mode: bool,
	neighbors: Array,
	others: PackedVector2Array
) -> void:
	while _renders.size() < neighbors.size() + 1:
		var vr := VolumeRender.new()
		add_child(vr)
		_renders.append(vr)
	for k in _renders.size():
		var vr := _renders[k]
		if k > neighbors.size():
			vr.visible = false
			continue
		if k == 0:
			vr.position = Vector3.ZERO
			vr.rotation = Vector3.ZERO
			vr.show_volume(
				vol, field_name, thr, abs_mode, exaggeration, density, others, storm_motion
			)
			continue
		var n: Dictionary = neighbors[k - 1]
		var off: Vector2 = n["offset_km"]
		vr.position = Vector3(off.x, 0, -off.y)
		vr.rotation = Vector3(0, -float(n["rotation"]), 0)
		var storm := storm_motion.rotated(n["rotation"])
		vr.show_volume(
			n["volume"], field_name, thr, abs_mode, exaggeration, density, n["others"], storm
		)


func _build_ground() -> void:
	var disk := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = GROUND_RADIUS_KM
	cyl.bottom_radius = GROUND_RADIUS_KM
	cyl.height = 0.01
	cyl.radial_segments = 128
	cyl.rings = 1
	disk.mesh = cyl
	disk.position.y = -0.1
	disk.material_override = _flat_material(Color(0.07, 0.08, 0.11))
	add_child(disk)

	var lines := PackedVector3Array()
	var r := RING_STEP_KM
	while r <= GROUND_RADIUS_KM - 1.0:
		_append_circle(lines, r, 0.02)
		r += RING_STEP_KM
	for k in 8:  # spokes every 45°
		var a := k * TAU / 8.0
		lines.append(Vector3.ZERO)
		lines.append(Vector3(sin(a), 0, -cos(a)) * (GROUND_RADIUS_KM - RING_STEP_KM + 20.0))
	add_child(_line_instance(lines, Color(1, 1, 1, 0.16)))


func _build_basemap() -> void:
	var bm := Basemap.get_shared()
	if bm == null:
		return
	var height := 0.04
	for layer in Basemap.LAYER_STYLE:
		if not bm.meshes.has(layer):
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = bm.meshes[layer]
		var mat := ShaderMaterial.new()
		mat.shader = BASEMAP_SHADER
		mat.set_shader_parameter("color", Basemap.LAYER_STYLE[layer])
		mat.set_shader_parameter("height_km", height)
		mat.set_shader_parameter("fade_km", GROUND_RADIUS_KM)
		height += 0.02  # later layers sit on top
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var r := GROUND_RADIUS_KM
		mi.custom_aabb = AABB(Vector3(-r, -1, -r), Vector3(2 * r, 2, 2 * r))
		add_child(mi)
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
	for label in _city_labels:
		label.queue_free()
	_city_labels.clear()
	var bm := Basemap.get_shared()
	if bm == null:
		return
	for c in bm.cities_near(lat, lon, CITY_RADIUS_KM).slice(0, CITY_MAX_LABELS):
		var label := Label3D.new()
		label.text = "· " + c[0]
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0008
		label.font_size = 22
		label.outline_size = 6
		label.modulate = Color(0.95, 0.95, 1.0, 0.8)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.position = Vector3(c[1].x, 0.2, -c[1].y)
		add_child(label)
		_city_labels.append(label)


func _build_height_scale() -> void:
	var lines := PackedVector3Array([Vector3.ZERO, Vector3(0, HEIGHT_MAX_KM, 0)])
	var h := HEIGHT_TICK_KM
	while h <= HEIGHT_MAX_KM:
		lines.append_array([Vector3(-3, h, 0), Vector3(3, h, 0)])
		lines.append_array([Vector3(0, h, -3), Vector3(0, h, 3)])
		var label := Label3D.new()
		label.text = "%d km" % int(h)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0007
		label.font_size = 24
		label.no_depth_test = true
		label.modulate = Color(1, 1, 1, 0.7)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		label.set_meta("height_km", h)
		add_child(label)
		_height_labels.append(label)
		h += HEIGHT_TICK_KM
	_height_lines = _line_instance(lines, Color(1, 1, 1, 0.6))
	add_child(_height_lines)
	_place_height_scale()


func _place_height_scale() -> void:
	_height_lines.scale = Vector3(1, exaggeration, 1)
	for label in _height_labels:
		label.position = Vector3(4, float(label.get_meta("height_km")) * exaggeration, 0)


static func _append_circle(lines: PackedVector3Array, r: float, y: float) -> void:
	var n := 256
	for k in n:
		var a0 := k * TAU / n
		var a1 := (k + 1) * TAU / n
		lines.append(Vector3(sin(a0) * r, y, -cos(a0) * r))
		lines.append(Vector3(sin(a1) * r, y, -cos(a1) * r))


static func _line_instance(lines: PackedVector3Array, color: Color) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = lines
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _flat_material(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


static func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	if color.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m
