extends "res://tests/test_case.gd"
## VolumeSource implementations: a MemorySource holding copies of the library's volumes (the
## shape nexrad-wasm hands over) must read exactly like the directory they came from.

const MemorySourceScript := preload("res://scripts/memory_source.gd")
const RadarLibraryScript := preload("res://scripts/radar_library.gd")
const VolumeCacheScript := preload("res://scripts/volume_cache.gd")

const MAX_VOLUMES := 3


func test_memory_matches_dir() -> void:
	var mem = MemorySourceScript.new()
	var names: Array[String] = []
	for v in lib.volumes.slice(0, MAX_VOLUMES):
		_copy(lib.source, mem, v)
		names.append(v)
	var mlib = RadarLibraryScript.new(mem)
	check_eq(mlib.volumes, names, "memory library volumes")
	for v in names:
		var a = lib.open(v)
		var b = mlib.open(v)
		if not check(b != null, "%s opens from memory" % v):
			continue
		check_eq(b.meta, a.meta, "%s meta" % v)
		check_eq(mlib.winds(v)["storm_motion"], lib.winds(v)["storm_motion"], "%s winds" % v)
		for f in ["REF", "VEL"]:
			for i in a.tilts(f):
				var ia: Image = a.read_image(i, f)
				var ib: Image = b.read_image(i, f)
				check(ib != null and ia.get_data() == ib.get_data(), "%s s%d %s image" % [v, i, f])
				for k in 5:
					var az := k * 71.3
					var r := 5.0 + k * 23.0
					check_eq(b.value_at(i, f, az, r), a.value_at(i, f, az, r), "%s value_at" % v)
	check(is_nan(mem.read_half(names[0], "missing.bin", 0)), "missing file reads NAN")


## Re-adding a volume (a live one that grew) makes loaded copies stale, and a VolumeCache on
## the source preloads from memory like it does from disk.
func test_memory_refresh_and_cache() -> void:
	var mem = MemorySourceScript.new()
	var v: String = lib.volumes[0]
	_copy(lib.source, mem, v)
	var vol = RadarVolume.open(mem, v)
	check(not vol.is_stale(), "fresh")
	_copy(lib.source, mem, v)
	check(vol.is_stale(), "stale after re-add")
	var cache = VolumeCacheScript.new(mem)
	var expected: int = cache.prefetch(v, "REF", 0.5, VolumeCacheScript.Need.ALL_TILTS)
	var loaded = cache.get_volume(v)
	check_eq(loaded.texture_bytes, expected, "preloaded from memory")
	mem.remove_volume(v)
	check_eq(mem.names().size(), 0, "removed")


static func _copy(from: VolumeSource, to, name: String) -> void:
	var text := from.read_meta(name)
	var files := {}
	for sw in (JSON.parse_string(text) as Dictionary)["sweeps"]:
		for fd in sw["fields"].values():
			files[fd["file"]] = from.read_file(name, fd["file"])
	to.add_volume(name, text, files)
