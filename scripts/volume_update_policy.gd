class_name VolumeUpdatePolicy
extends RefCounted
## Decides which view changes when a decoded volume replaces one under the same name.


static func shown_in_loop(
	name: String, current: RadarVolume, frames: Array[String], frame: int
) -> bool:
	if current == null or frames.is_empty():
		return false
	var index := frames.find(name)
	var seq := RadarLibrary.sequence_bounds(frames, frame)
	return index >= seq.x and index <= seq.y


## Empty means the current frame should remain pinned. Newest wins even if an older
## provisional scan arrives later; a rewritten newest scan must reload when it is stale.
static func live_target(
	library: RadarLibrary, site: String, current: RadarVolume, playing: bool
) -> String:
	var newest := library.latest(site)
	if newest.is_empty() or playing:
		return ""
	if current != null and current.name == newest and not current.is_stale():
		return ""
	return newest


static func quality(vol: RadarVolume) -> String:
	return (
		"  (partial)" if not vol.is_complete() else ("  (provisional)" if vol.provisional else "")
	)
