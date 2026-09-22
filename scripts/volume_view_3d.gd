class_name VolumeView3D
extends Node3D
## 3D volume view: every tilt of one field as a cone (cone.gdshader), over a ground disk
## with range rings and a height scale at the radar. Heights are exaggerated for legibility.

enum Isolate { ALL, BELOW, SINGLE }

const RADIAL_SEGMENTS := 64
const AZIMUTH_SEGMENTS := 360
const GROUND_RADIUS_KM := 480.0
const RING_STEP_KM := 50.0
const HEIGHT_TICK_KM := 5.0
const HEIGHT_MAX_KM := 20.0
const DEFAULT_EXAGGERATION := 4.0
const EXAGGERATION_MIN := 1.0
const EXAGGERATION_MAX := 20.0
const ISOLATE_NAMES := ["all tilts", "selected and below", "selected only"]

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
}

var exaggeration := DEFAULT_EXAGGERATION
var isolate := Isolate.ALL
var thresholds: Dictionary = {}  # field -> float; overrides DEFAULT_THRESHOLDS
var _cone_mesh: ArrayMesh
var _shader: Shader = preload("res://shaders/cone.gdshader")
var _cones: Array[MeshInstance3D] = []
var _height_lines: MeshInstance3D  # built in true km, scaled on y by exaggeration
var _height_labels: Array[Label3D] = []

@onready var camera: OrbitCamera = $Camera
@onready var cones_root: Node3D = $Cones


func _ready() -> void:
	_cone_mesh = _build_cone_mesh()
	_build_ground()
	_build_height_scale()


func set_active(on: bool) -> void:
	visible = on
	camera.current = on


func threshold_of(field_name: String) -> float:
	return thresholds.get(field_name, DEFAULT_THRESHOLDS.get(field_name, [-10000.0])[0])


func adjust_threshold(field_name: String, steps: int) -> void:
	var rng := Colormaps.range_of(field_name)
	var step: float = (rng[1] - rng[0]) / 22.0
	var t := threshold_of(field_name)
	var lo: float = rng[0] - step
	if DEFAULT_THRESHOLDS.get(field_name, [0.0, false])[1]:
		lo = 0.0
	thresholds[field_name] = clampf(snappedf(t + steps * step, 0.01), lo, rng[1])


func set_exaggeration(v: float) -> void:
	exaggeration = clampf(v, EXAGGERATION_MIN, EXAGGERATION_MAX)
	_place_height_scale()
	for c in _cones:
		(c.material_override as ShaderMaterial).set_shader_parameter("exaggeration", exaggeration)
		c.custom_aabb = _cone_aabb()


## Draw all tilts of `field_name`, honouring the isolate mode relative to tilt `selected`.
func show_volume(vol: RadarVolume, field_name: String, selected: int) -> void:
	var tilts: Array[int] = vol.tilts(field_name) if vol != null else ([] as Array[int])
	var sel_elev := vol.elevation(selected) if selected >= 0 else 0.0
	var shown: Array[int] = []
	for i in tilts:
		match isolate:
			Isolate.SINGLE:
				if i == selected:
					shown.append(i)
			Isolate.BELOW:
				if vol.elevation(i) <= sel_elev:
					shown.append(i)
			_:
				shown.append(i)
	while _cones.size() < shown.size():
		_cones.append(_new_cone())
	var rng := Colormaps.range_of(field_name)
	var abs_mode: bool = DEFAULT_THRESHOLDS.get(field_name, [0.0, false])[1]
	for k in _cones.size():
		var cone := _cones[k]
		cone.visible = k < shown.size()
		if not cone.visible:
			continue
		var i := shown[k]
		var f: Dictionary = vol.sweep(i)["fields"][field_name]
		var mat := cone.material_override as ShaderMaterial
		mat.set_shader_parameter("sweep", vol.get_texture(i, field_name))
		mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
		mat.set_shader_parameter("cmap_min", rng[0])
		mat.set_shader_parameter("cmap_max", rng[1])
		mat.set_shader_parameter("elevation_deg", vol.elevation(i))
		mat.set_shader_parameter("first_gate_km", float(f["first_gate_m"]) / 1000.0)
		mat.set_shader_parameter("gate_spacing_km", float(f["gate_spacing_m"]) / 1000.0)
		mat.set_shader_parameter("n_gates", int(f["n_gates"]))
		mat.set_shader_parameter("threshold", threshold_of(field_name))
		mat.set_shader_parameter("threshold_abs", abs_mode)
		# Draw low tilts first; with opaque cones this only matters for equal depth.
		cone.sorting_offset = -vol.elevation(i)


func _new_cone() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _cone_mesh
	var mat := ShaderMaterial.new()
	mat.shader = _shader
	mat.set_shader_parameter("exaggeration", exaggeration)
	mi.material_override = mat
	mi.custom_aabb = _cone_aabb()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cones_root.add_child(mi)
	return mi


func _cone_aabb() -> AABB:
	var r := GROUND_RADIUS_KM + 20.0
	return AABB(Vector3(-r, -1.0, -r), Vector3(2 * r, 30.0 * exaggeration + 2.0, 2 * r))


## Unit grid; cone.gdshader positions the vertices. UV.x = range fraction, UV.y = azimuth.
static func _build_cone_mesh() -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for a in AZIMUTH_SEGMENTS + 1:
		for r in RADIAL_SEGMENTS + 1:
			var uv := Vector2(float(r) / RADIAL_SEGMENTS, float(a) / AZIMUTH_SEGMENTS)
			uvs.append(uv)
			verts.append(Vector3(uv.x, 0, uv.y))  # placeholder; replaced in the shader
	var row := RADIAL_SEGMENTS + 1
	for a in AZIMUTH_SEGMENTS:
		for r in RADIAL_SEGMENTS:
			var i := a * row + r
			idx.append_array([i, i + 1, i + row, i + 1, i + row + 1, i + row])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


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
