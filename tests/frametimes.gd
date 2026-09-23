extends SceneTree
## Plays the main scene and reports frame-time spikes (needs a display):
##   godot --path . --script res://tests/frametimes.gd -- frames=600 view=3d play=1 ...
## Other key=value options go to main.gd; prefetch=0 turns background loading off.
## Budgets (tests/perf.sh sets them): max_median= (ms), max_p99_ratio= (p99 / median) and
## max_spikes= (frames over spike_ratio= × the median, default 4; or over spike_ms= if given).
## Ratios keep the gate meaningful on any machine, software rendering included. Exits 1 when
## any budget is exceeded.

var _frames := 600
var _spike_ms := 0.0  # absolute spike threshold; 0 = _spike_ratio × median
var _spike_ratio := 4.0
var _budget := {}  # max_median / max_p99_ratio / max_spikes -> limit
var _times: PackedFloat32Array = []
var _last := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var key := a.get_slice("=", 0)
		var value := a.get_slice("=", 1)
		if key == "frames":
			_frames = value.to_int()
		elif key == "spike_ms":
			_spike_ms = value.to_float()
		elif key == "spike_ratio":
			_spike_ratio = value.to_float()
		elif key in ["max_median", "max_p99_ratio", "max_spikes"]:
			_budget[key] = value.to_float()
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
	var median: float = sorted[sorted.size() / 2]
	var p99: float = sorted[int(sorted.size() * 0.99)]
	var spike := _spike_ms if _spike_ms > 0.0 else _spike_ratio * median
	var over := 0
	for k in _times.size():
		if _times[k] > spike:
			over += 1
			print("  spike at sample %d: %.0f ms" % [k, _times[k]])
	var worst := PackedStringArray()
	for t in sorted.slice(-8):
		worst.append("%.0f" % t)
	var got := {
		"max_median": median,
		"max_p99_ratio": p99 / median,
		"max_spikes": over,
	}
	print(
		(
			"frames %d  median %.1f ms  p99 %.1f ms  >%.0f ms: %d  worst %s"
			% [_times.size(), median, p99, spike, over, " ".join(worst)]
		)
	)
	var broken := PackedStringArray()
	for key in _budget:
		if got[key] > _budget[key]:
			broken.append("%s %.2f > %.2f" % [key.trim_prefix("max_"), got[key], _budget[key]])
	if not _budget.is_empty():
		print("budget: " + ("FAIL (" + ", ".join(broken) + ")" if broken else "ok"))
	quit(1 if broken else 0)
	return true
