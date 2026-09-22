extends SceneTree
## Checks that the 3D hover pick (VolumeView3D.pick) reports what is drawn: renders the main
## scene (needs a display; tests/golden.sh runs it under Xvfb), picks random pixel centres and
## compares each rendered pixel with the colormap colour of the picked value. Exits 1 unless
## at least MIN_SHARE of at least MIN_PICKS picks match (the rest are cone edges).
##   godot --path . --script res://tests/pick_check.gd -- view=3d volumes=... site=KTST ...

const MIN_PICKS := 20
const MIN_SHARE := 0.9
const TOLERANCE := 0.12
const FRAMES := 40

var _frame := 0


func _initialize() -> void:
	change_scene_to_file("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame < FRAMES:
		return false
	var main = current_scene
	var v3: VolumeView3D = main.view_3d
	var field: String = main.field_name
	var img := root.get_viewport().get_texture().get_image()
	var cmap := Colormaps.texture_for(field).get_image()
	var rng := Colormaps.range_of(field)
	var size := img.get_size()
	var rnd := RandomNumberGenerator.new()
	rnd.seed = 3
	var good := 0
	var total := 0
	for k in 3000:
		if total >= 200:
			break
		var px := Vector2i(
			rnd.randi_range(0, size.x - 1), rnd.randi_range(size.y / 8, size.y * 7 / 8)
		)
		var hit := v3.pick(Vector2(px) + Vector2(0.5, 0.5))
		if not hit.has("sweep"):
			continue
		total += 1
		var t := clampf((hit["value"] - rng[0]) / (rng[1] - rng[0]), 0.0, 1.0)
		var want := cmap.get_pixel(int(t * (cmap.get_width() - 1)), 0)
		var got := img.get_pixel(px.x, px.y)
		if Vector3(got.r - want.r, got.g - want.g, got.b - want.b).length() < TOLERANCE:
			good += 1
	var ok := total >= MIN_PICKS and good >= MIN_SHARE * total
	print(
		(
			"pick_check: %d of %d picks match the rendered colour (%s)"
			% [good, total, "ok" if ok else "FAIL"]
		)
	)
	quit(0 if ok else 1)
	return true
