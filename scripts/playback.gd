class_name Playback
extends RefCounted
## Playback arithmetic for main.gd: where a step, a loop tick or a sequence jump lands within
## `frames` (a site's scans inside the window, ascending), the loop's volumes and VWP columns,
## and the speed steps. `seq` is RadarLibrary.sequence_bounds() of the current frame.

const LOOP_DWELL_SEC := 1.0  # extra pause on the last frame of the loop


## The frame after `frame` in the loop, wrapping to the sequence's start.
static func next_frame(frame: int, seq: Vector2i) -> int:
	return frame + 1 if frame < seq.y else seq.x


## Seconds to show frame `next` for at `fps`: longer on the loop's last frame.
static func frame_wait(next: int, seq: Vector2i, fps: float) -> float:
	return 1.0 / fps + (LOOP_DWELL_SEC if next == seq.y else 0.0)


## The first frame of the next sequence (`delta` > 0) or the last of the previous one, or -1
## when there is none.
static func sequence_jump(frames: Array[String], seq: Vector2i, delta: int) -> int:
	var i := seq.y + 1 if delta > 0 else seq.x - 1
	return i if i >= 0 and i < frames.size() else -1


## The speed `delta` steps from `fps` along Hud.SPEEDS (from the default when `fps` is not one).
static func cycle_speed(fps: float, delta: int) -> float:
	var i := Hud.SPEEDS.find(fps)
	if i < 0:
		i = Hud.DEFAULT_SPEED_INDEX
	return Hud.SPEEDS[clampi(i + delta, 0, Hud.SPEEDS.size() - 1)]


## The loaded volumes of the sequence, oldest first.
static func loop_volumes(
	cache: VolumeCache, frames: Array[String], seq: Vector2i
) -> Array[RadarVolume]:
	var out: Array[RadarVolume] = []
	for k in range(seq.x, seq.y + 1):
		var v := cache.get_volume(frames[k])
		if v != null:
			out.append(v)
	return out


## The VWP's columns for the sequence: [{path, t, profile}] (WindProfileView.show_profiles).
static func vwp_columns(library: RadarLibrary, frames: Array[String], seq: Vector2i) -> Array:
	var columns := []
	for k in range(seq.x, seq.y + 1):
		var path := frames[k]
		var profile = library.winds(path).get("wind_profile")
		columns.append({"path": path, "t": RadarLibrary.unix_of(path), "profile": profile})
	return columns
