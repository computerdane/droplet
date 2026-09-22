extends SceneTree
## Plays the main scene and reports frame-time spikes (needs a display):
##   godot --path . --script res://tests/frametimes.gd -- frames=600 view=3d play=1 ...
## Other key=value options go to main.gd; prefetch=0 turns background loading off.

var _frames := 600
var _times: PackedFloat32Array = []
var _last := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("frames="):
			_frames = a.get_slice("=", 1).to_int()
	change_scene_to_file("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if _last > 0 and get_frame() > 10:
		_times.append((now - _last) / 1000.0)
	_last = now
	if _times.size() < _frames:
		return false
	var sorted := _times.duplicate()
	sorted.sort()
	var over := 0
	for k in _times.size():
		if _times[k] > 20.0:
			over += 1
			print("  spike at sample %d: %.0f ms" % [k, _times[k]])
	var worst := PackedStringArray()
	for t in sorted.slice(-8):
		worst.append("%.0f" % t)
	print(
		(
			"frames %d  median %.1f ms  p99 %.1f ms  >20 ms: %d  worst %s"
			% [
				_times.size(),
				sorted[sorted.size() / 2],
				sorted[int(sorted.size() * 0.99)],
				over,
				" ".join(worst)
			]
		)
	)
	quit()
	return true
