class_name ConeSet
extends Node3D
## The tilts of one radar volume as cones (cone.gdshader), in the radar's local frame.
## VolumeView3D keeps one for the selected site and one per mosaic neighbour, placing
## each at its site's projected offset.

enum Isolate { ALL, BELOW, SINGLE }

const RADIAL_SEGMENTS := 64
const AZIMUTH_SEGMENTS := 360
const AABB_RADIUS_KM := 500.0
const CONE_SHADER := preload("res://shaders/cone.gdshader")

static var _mesh: ArrayMesh

var storm_motion := Vector2.ZERO  # m/s east, north in this radar's frame; zero = off
var _cones: Array[MeshInstance3D] = []
# What show_volume() drew, for pick().
var _vol: RadarVolume
var _field := ""
var _shown: Array[int] = []
var _threshold := 0.0
var _threshold_abs := false
var _exaggeration := 1.0
var _others := PackedVector2Array()


## Draw the tilts of `field_name` in `vol`, filtered by `isolate` relative to the tilt
## nearest `sel_elev`. `threshold` hides weaker values (|value| when `threshold_abs`).
## `others` are other mosaic radars in this set's local frame (+x east, +y south).
func show_volume(
	vol: RadarVolume,
	field_name: String,
	sel_elev: float,
	isolate: Isolate,
	threshold: float,
	threshold_abs: bool,
	exaggeration: float,
	others := PackedVector2Array()
) -> void:
	var shown: Array[int] = []
	if vol != null:
		var selected := vol.tilt_near(field_name, sel_elev)
		for i in vol.tilts(field_name):
			match isolate:
				Isolate.SINGLE:
					if i == selected:
						shown.append(i)
				Isolate.BELOW:
					if vol.elevation(i) <= vol.elevation(selected):
						shown.append(i)
				_:
					shown.append(i)
	_vol = vol
	_field = field_name
	_shown = shown
	_threshold = threshold
	_threshold_abs = threshold_abs
	_others = others
	while _cones.size() < shown.size():
		_cones.append(_new_cone())
	var rng := Colormaps.range_of(field_name)
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
		mat.set_shader_parameter("threshold", threshold)
		mat.set_shader_parameter("threshold_abs", threshold_abs)
		mat.set_shader_parameter("other_sites", others)
		mat.set_shader_parameter("n_other_sites", others.size())
		mat.set_shader_parameter("storm_motion", storm_motion)
	set_exaggeration(exaggeration)


func set_exaggeration(exaggeration: float) -> void:
	_exaggeration = exaggeration
	var r := AABB_RADIUS_KM
	var aabb := AABB(Vector3(-r, -1.0, -r), Vector3(2 * r, 30.0 * exaggeration + 2.0, 2 * r))
	for c in _cones:
		(c.material_override as ShaderMaterial).set_shader_parameter("exaggeration", exaggeration)
		c.custom_aabb = aabb


func _new_cone() -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _cone_mesh()
	var mat := ShaderMaterial.new()
	mat.shader = CONE_SHADER
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## Unit grid shared by all cones; cone.gdshader positions the vertices.
## UV.x = range fraction, UV.y = azimuth fraction.
static func _cone_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
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
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _mesh


## First place along a ray (in this set's local frame, y exaggerated) where it meets a drawn
## cone: CPU twin of cone.gdshader's discard rules. Steps along the ray, turning each point
## into the elevation angle of the beam through it (4/3 earth, as section.gdshader), and
## looks for the shown tilts crossed between steps. Returns {t, sweep, az, r (slant km), s
## (ground km), h (km above the radar), value} or {} if nothing drawn is hit within max_t.
func pick(origin: Vector3, dir: Vector3, max_t: float, step: float) -> Dictionary:
	if not visible or _vol == null or _shown.is_empty():
		return {}
	var elevs := PackedFloat32Array()
	for i in _shown:
		elevs.append(_vol.elevation(i))
	var prev_t := 0.0
	var prev_e := _elevation_at(origin)
	var t := step
	while t <= max_t:
		var e := _elevation_at(origin + dir * t)
		if not is_nan(prev_e) and not is_nan(e):
			var lo := minf(prev_e, e)
			var hi := maxf(prev_e, e)
			var order := range(elevs.size())
			if e < prev_e:
				order.reverse()  # descending: meet the higher tilts first
			for k in order:
				if elevs[k] < lo or elevs[k] > hi or hi == lo:
					continue
				var tk := lerpf(prev_t, t, (elevs[k] - prev_e) / (e - prev_e))
				var hit := _sample(_shown[k], origin + dir * tk)
				if not hit.is_empty():
					hit["t"] = tk
					return hit
		prev_t = t
		prev_e = e
		t += step
	return {}


## Beam elevation (degrees) through a local point, or NAN below the ground.
func _elevation_at(p: Vector3) -> float:
	var h := p.y / _exaggeration
	if h < 0.0:
		return NAN
	var s := Vector2(p.x, p.z).length()
	var ka := SectionView.KE_A
	var phi := s / ka
	var half := sin(0.5 * phi)
	return rad_to_deg(atan2(h * cos(phi) - 2.0 * ka * half * half, (ka + h) * sin(phi)))


## The value drawn at a point of tilt `i`'s cone, or {} if the shader would discard it.
func _sample(i: int, p: Vector3) -> Dictionary:
	var ground := Vector2(p.x, p.z)  # +x east, +y south, like the shader's `ground`
	var s := ground.length()
	for o in _others:
		if ground.distance_to(o) < s:
			return {}
	var ka := SectionView.KE_A
	var th := deg_to_rad(_vol.elevation(i))
	var phi := s / ka
	var c := cos(th + phi)
	if c <= 0.0:
		return {}
	var r := ka * sin(phi) / c
	var az := fposmod(rad_to_deg(atan2(ground.x, -ground.y)), 360.0)
	var v := RadarVolume.storm_relative(
		_vol.value_at(i, _field, az, r), storm_motion, az, rad_to_deg(th)
	)
	if v < -900.0 or (absf(v) if _threshold_abs else v) < _threshold:
		return {}
	return {
		"sweep": i, "az": az, "r": r, "s": s, "h": p.y / _exaggeration, "value": v, "volume": _vol
	}
