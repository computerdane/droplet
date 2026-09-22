class_name Overlay3D
extends MeshInstance3D
## Lines over the 3D view, in the selected radar's frame (km, +x east, -z north, y = height x
## exaggeration): the cross-section's A-B curtain, NWS warning polygons on the ground, and
## storm cells as a stalk up to their echo top over their ground track and forecast. One
## ImmediateMesh with vertex colours, rebuilt when anything changes.

const SECTION_COLOR := Color(1, 1, 1, 0.8)
const SECTION_TOP_KM := 20.0
const GROUND_Y := 0.08
const TRACK_COLOR := Color(1, 1, 1, 0.7)
const FORECAST_COLOR := Color(0.55, 0.85, 1.0, 0.9)

var exaggeration := 4.0
var _section := []  # [a, b] (Vector2 km, +x east, +y south) or empty
var _warnings: Array = []  # Warnings.project()
var _cells: Array = []  # StormCells.track() entries
var _labels: Array[Label3D] = []


func _ready() -> void:
	mesh = ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for text in ["A", "B"]:
		var label := Label3D.new()
		label.text = text
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.fixed_size = true
		label.pixel_size = 0.0012
		label.font_size = 24
		label.outline_size = 8
		label.visible = false
		add_child(label)
		_labels.append(label)


func set_section(on: bool, a: Vector2, b: Vector2) -> void:
	_section = [a, b] if on and a != b else []
	_rebuild()


func set_overlays(warning_polys: Array, cells: Array) -> void:
	_warnings = warning_polys
	_cells = cells
	_rebuild()


func set_exaggeration(v: float) -> void:
	exaggeration = v
	_rebuild()


static func _at(p: Vector2, h_km: float, exag: float) -> Vector3:
	return Vector3(p.x, h_km * exag, p.y)


func _rebuild() -> void:
	var im := mesh as ImmediateMesh
	if im == null:
		return
	im.clear_surfaces()
	var lines := PackedVector3Array()
	var colors := PackedColorArray()
	var add := func(p: Vector3, q: Vector3, c: Color) -> void:
		lines.append_array([p, q])
		colors.append_array([c, c])
	var ground := GROUND_Y / exaggeration  # km, so it stays just above the disk
	for w in _warnings:
		for ring: PackedVector2Array in w["rings"]:
			for k in ring.size() - 1:
				add.call(
					_at(ring[k], ground, exaggeration),
					_at(ring[k + 1], ground, exaggeration),
					w["color"]
				)
	for c in _cells:
		var pos := Vector2(c["pos"].x, -c["pos"].y)
		var tr: PackedVector2Array = c["track"]
		for k in tr.size() - 1:
			var p := Vector2(tr[k].x, -tr[k].y)
			var q := Vector2(tr[k + 1].x, -tr[k + 1].y)
			add.call(_at(p, ground, exaggeration), _at(q, ground, exaggeration), TRACK_COLOR)
		var ahead := StormCells.forecast(c)
		if not ahead.is_empty():
			var end := Vector2(ahead[-1].x, -ahead[-1].y)
			add.call(_at(pos, ground, exaggeration), _at(end, ground, exaggeration), FORECAST_COLOR)
		var rot := float(c["rot"])
		var col := Color.WHITE
		if c["tds"]:
			col = Color(1, 0.1, 0.8)
		elif rot >= StormCells.ROT_STRONG:
			col = Color(1, 0.15, 0.15)
		elif rot >= StormCells.ROT_MESO:
			col = Color(1, 0.85, 0)
		add.call(
			_at(pos, 0.0, exaggeration), _at(pos, maxf(float(c["top_km"]), 1.0), exaggeration), col
		)
	var show_section := not _section.is_empty()
	if show_section:
		var a: Vector2 = _section[0]
		var b: Vector2 = _section[1]
		var top := SECTION_TOP_KM
		add.call(_at(a, 0.0, exaggeration), _at(b, 0.0, exaggeration), SECTION_COLOR)
		add.call(
			_at(a, top, exaggeration),
			_at(b, top, exaggeration),
			SECTION_COLOR * Color(1, 1, 1, 0.5)
		)
		add.call(_at(a, 0.0, exaggeration), _at(a, top, exaggeration), SECTION_COLOR)
		add.call(_at(b, 0.0, exaggeration), _at(b, top, exaggeration), SECTION_COLOR)
		_labels[0].position = _at(a, top, exaggeration) + Vector3(0, 2, 0)
		_labels[1].position = _at(b, top, exaggeration) + Vector3(0, 2, 0)
	for label in _labels:
		label.visible = show_section
	if lines.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for k in lines.size():
		im.surface_set_color(colors[k])
		im.surface_add_vertex(lines[k])
	im.surface_end()
