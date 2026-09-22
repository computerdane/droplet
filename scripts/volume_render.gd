class_name VolumeRender
extends MeshInstance3D
## One radar volume drawn translucently by ray marching (volume.gdshader) through a
## TiltArray of the field. Placed like a ConeSet: in the radar's local frame, offset and
## rotated for mosaic neighbours by VolumeView3D.

const VOLUME_SHADER := preload("res://shaders/volume.gdshader")
const TOP_KM := 20.0
const MAX_LAYERS := 24
const LUT_STEP_DEG := 0.25
const LUT_SIZE := 160
const BEAMWIDTH_DEG := 0.95

var _mat: ShaderMaterial


func _init() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(2, 1, 2)  # stretched over the data by the shader
	mesh = box
	_mat = ShaderMaterial.new()
	_mat.shader = VOLUME_SHADER
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Draw `field_name` of `vol`; returns false (and hides) if it has no tilts of it.
## `threshold` (|value| when `threshold_abs`) is where opacity starts; `others` are other
## mosaic radars in this local frame (+x east, +y south); `storm` as ConeSet.storm_motion.
func show_volume(
	vol: RadarVolume,
	field_name: String,
	threshold: float,
	threshold_abs: bool,
	exaggeration: float,
	density: float,
	others: PackedVector2Array,
	storm: Vector2
) -> bool:
	var ta: TiltArray = TiltArray.of(vol, field_name) if vol != null else null
	visible = ta != null and ta.elevations.size() > 0
	if not visible:
		return false
	var n := mini(ta.elevations.size(), MAX_LAYERS)
	var elevs := ta.elevations.slice(0, n)
	var geom := PackedVector3Array()
	for k in n:
		geom.append(Vector3(ta.first_gate_km[k], ta.gate_spacing_km[k], ta.n_gates[k]))
	var lut := PackedInt32Array()
	for b in LUT_SIZE:
		var k := -1
		while k + 1 < n and elevs[k + 1] <= b * LUT_STEP_DEG:
			k += 1
		lut.append(k)
	var rng := Colormaps.range_of(field_name)
	_mat.set_shader_parameter("tilts", ta.texture)
	_mat.set_shader_parameter("colormap", Colormaps.texture_for(field_name))
	_mat.set_shader_parameter("n_layers", n)
	_mat.set_shader_parameter("elevs", elevs)
	_mat.set_shader_parameter("geom", geom)
	_mat.set_shader_parameter("layer_lut", lut)
	_mat.set_shader_parameter("width", float(ta.width))
	_mat.set_shader_parameter("radius_km", ta.max_range_km)
	_mat.set_shader_parameter("top_km", TOP_KM)
	_mat.set_shader_parameter("half_beam_deg", BEAMWIDTH_DEG / 2.0)
	_mat.set_shader_parameter("cmap_min", rng[0])
	_mat.set_shader_parameter("cmap_max", rng[1])
	_mat.set_shader_parameter("threshold", threshold)
	_mat.set_shader_parameter("threshold_abs", threshold_abs)
	_mat.set_shader_parameter("density", density)
	_mat.set_shader_parameter("other_sites", others)
	_mat.set_shader_parameter("n_other_sites", others.size())
	_mat.set_shader_parameter("storm_motion", storm)
	set_exaggeration(exaggeration, ta.max_range_km)
	return true


func set_exaggeration(exaggeration: float, radius_km := -1.0) -> void:
	_mat.set_shader_parameter("exaggeration", exaggeration)
	var r: float = radius_km if radius_km > 0.0 else _mat.get_shader_parameter("radius_km")
	custom_aabb = AABB(Vector3(-r, -1.0, -r), Vector3(2 * r, TOP_KM * exaggeration + 2.0, 2 * r))
