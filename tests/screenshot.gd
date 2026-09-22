extends SceneTree
## Renders the main scene for a few frames and saves a PNG (needs a display, not --headless):
##   godot --path . --script res://tests/screenshot.gd [--] out.png

const FRAMES := 30


func _initialize() -> void:
	change_scene_to_file("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	if get_frame() < FRAMES:
		return false
	var args := OS.get_cmdline_user_args()
	var out := args[0] if args.size() > 0 else "user://screenshot.png"
	var err := root.get_viewport().get_texture().get_image().save_png(out)
	print("screenshot: ", out, " (", error_string(err), ")")
	quit(0 if err == OK else 1)
	return true
