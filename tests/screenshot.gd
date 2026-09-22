extends SceneTree
## Renders the main scene for a few frames and saves a PNG (needs a display, not --headless):
##   godot --path . --script res://tests/screenshot.gd -- out.png [key=value ...]
## key=value options go to main.gd (site=, time=, field=, elev=, view=3d, ...);
## frames=N sets how many frames to render before capturing (default 30).

const DEFAULT_FRAMES := 30

var _frames := DEFAULT_FRAMES
var _out := "user://screenshot.png"


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("frames="):
			_frames = a.get_slice("=", 1).to_int()
		elif not "=" in a:
			_out = a
	change_scene_to_file("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	if get_frame() < _frames:
		return false
	if current_scene == null or current_scene.get_script() == null:
		push_error("main scene failed to load or its script did not compile")
		quit(1)
		return true
	var err := root.get_viewport().get_texture().get_image().save_png(_out)
	print("screenshot: ", _out, " (", error_string(err), ")")
	quit(0 if err == OK else 1)
	return true
