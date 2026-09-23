extends SceneTree
## Plays the main scene and reports frame-time spikes (needs a display):
##   godot --path . --script res://tests/frametimes.gd -- frames=600 view=3d play=1 ...
## Other key=value options go to main.gd; prefetch=0 turns background loading off.
## Budgets (tests/perf.sh sets them): max_median= (ms), max_p99_ratio= (p99 / median) and
## max_spikes= (frames over spike_ratio= × the median, default 4; or over spike_ms= if given).
## Ratios keep the gate meaningful on any machine, software rendering included; ratio_floor_ms=
## (default 0) is the least median they are taken against, so a fast machine's tiny median does
## not turn invisible hitches into failures. The absolute
## cost of a frame is budgeted as work, which is the same on every machine: max_draw_calls= and
## max_primitives= (the most in any frame) and max_video_mb= (peak video memory). The GPU time
## the renderer measures is reported, not budgeted (it is the runner's CPU under llvmpipe).
## Exits 1 when any budget is exceeded.

const BUDGETS := [
	"max_median", "max_p99_ratio", "max_spikes", "max_draw_calls", "max_primitives", "max_video_mb"
]

var _frames := 600
var _spike_ms := 0.0  # absolute spike threshold; 0 = _spike_ratio × median
var _spike_ratio := 4.0
var _ratio_floor_ms := 0.0
var _budget := {}  # max_median / max_p99_ratio / max_spikes -> limit
var _times: PackedFloat32Array = []
var _gpu_ms: PackedFloat32Array = []
var _draw_calls := 0
var _primitives := 0
var _video_mb := 0.0
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
		elif key == "ratio_floor_ms":
			_ratio_floor_ms = value.to_float()
		elif key in BUDGETS:
			_budget[key] = value.to_float()
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	change_scene_to_file("res://scenes/main.tscn")


func _process(_delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if _last > 0 and get_frame() > 10:
		_times.append((now - _last) / 1000.0)
		# Counters of the frame drawn last.
		_draw_calls = maxi(
			_draw_calls, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		)
		_primitives = maxi(
			_primitives, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		)
		_video_mb = maxf(
			_video_mb, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
		)
		_gpu_ms.append(
			RenderingServer.viewport_get_measured_render_time_gpu(root.get_viewport_rid())
		)
	_last = now
	if _times.size() < _frames:
		return false
	var sorted := _times.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	var p99: float = sorted[int(sorted.size() * 0.99)]
	var base := maxf(median, _ratio_floor_ms)  # what the ratios are taken against
	var spike := _spike_ms if _spike_ms > 0.0 else _spike_ratio * base
	var over := 0
	for k in _times.size():
		if _times[k] > spike:
			over += 1
			print("  spike at sample %d: %.0f ms" % [k, _times[k]])
	var worst := PackedStringArray()
	for t in sorted.slice(-8):
		worst.append("%.0f" % t)
	var gpu := _gpu_ms.duplicate()
	gpu.sort()
	print(
		(
			"work: draw calls <= %d  primitives <= %d  video memory <= %.0f MB  GPU median %.1f ms"
			% [_draw_calls, _primitives, _video_mb, gpu[gpu.size() / 2]]
		)
	)
	var got := {
		"max_median": median,
		"max_p99_ratio": p99 / base,
		"max_spikes": over,
		"max_draw_calls": _draw_calls,
		"max_primitives": _primitives,
		"max_video_mb": _video_mb,
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
