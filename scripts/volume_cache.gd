class_name VolumeCache
extends RefCounted
## LRU of loaded RadarVolumes so animation loops do not re-read disk or re-upload textures.
## Evicts least recently used volumes once their combined texture bytes exceed the budget.

const DEFAULT_BUDGET_BYTES := 1024 * 1024 * 1024

var budget_bytes: int
var _volumes: Dictionary = {}  # path -> RadarVolume
var _order: Array[String] = []  # least recently used first


func _init(p_budget_bytes: int = DEFAULT_BUDGET_BYTES) -> void:
	budget_bytes = p_budget_bytes


## Returns the cached volume for `path`, loading it if needed. Incomplete (live) volumes are
## reloaded when `refresh` is set and the sidecar has rewritten them since.
func get_volume(path: String, refresh := false) -> RadarVolume:
	var vol: RadarVolume = _volumes.get(path)
	if vol != null and refresh and not vol.is_complete() and vol.is_stale():
		vol = null
	if vol == null:
		vol = RadarVolume.load_from_dir(path)
		if vol == null:
			return null
		_volumes[path] = vol
	_order.erase(path)
	_order.append(path)
	_evict()
	return vol


func used_bytes() -> int:
	var total := 0
	for v in _volumes.values():
		total += (v as RadarVolume).texture_bytes
	return total


func _evict() -> void:
	# Never evict the most recent entry: it is the one being shown.
	while _order.size() > 1 and used_bytes() > budget_bytes:
		_volumes.erase(_order.pop_front())
