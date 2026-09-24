extends "res://tests/test_case.gd"
## VolumeSource implementations: a MemorySource holding copies of the library's volumes (the
## shape nexrad-wasm hands over) must read exactly like the directory they came from.

const MemorySourceScript := preload("res://scripts/memory_source.gd")
const RadarLibraryScript := preload("res://scripts/radar_library.gd")
const VolumeCacheScript := preload("res://scripts/volume_cache.gd")
const FetcherScript := preload("res://scripts/fetcher.gd")

const MAX_VOLUMES := 3


func test_dir_same_second_replacement() -> void:
	var source := DirSource.new(lib.source.describe())
	var name: String = lib.volumes[0]
	var before := source.version(name)
	source.mark_updated(name)
	check(source.version(name) != before, "same-second completed write changes version")
	var updated := source.version(name)
	source.mark_updated(name)
	check(source.version(name) != updated, "every replacement changes version")


func test_fetcher_reports_same_name_writes() -> void:
	var fetcher := FetcherScript.new()
	fetcher.web = false
	var reported: Array[String] = []
	fetcher.volume_written.connect(func(name: String) -> void: reported.append(name))
	var job := FetcherScript.Job.new()
	var name := "KTST_20240501_000000"
	fetcher._add_line(job, "/data/volumes/" + name)
	fetcher._add_line(job, "/data/volumes/" + name)
	fetcher._add_line(job, name + ": 5 sweeps (3 chunks) complete")
	fetcher._add_line(job, "backfill finalize /data/volumes/" + name + ": failed")
	check_eq(reported, [name, name, name], "replacements and chunk summaries notify, errors do not")
	check_eq(job.volumes, [name], "arrival names stay unique")
	fetcher.free()


func test_provisional_quality_survives_reopen() -> void:
	var source := MemorySourceScript.new()
	var name: String = lib.volumes[0]
	var meta: Dictionary = JSON.parse_string(lib.source.read_meta(name))
	meta["provisional"] = true
	source.add_volume(name, JSON.stringify(meta), {})
	check(RadarVolume.open(source, name).provisional, "interrupted preview remains provisional")
	meta.erase("provisional")
	source.add_volume(name, JSON.stringify(meta), {})
	check(not RadarVolume.open(source, name).provisional, "final replacement clears quality flag")


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


## A budget evicts the oldest other volumes, never the one just added.
func test_memory_budget() -> void:
	var names: Array = lib.volumes.slice(0, MAX_VOLUMES)
	if names.size() < 2:
		return
	names.sort_custom(func(a: String, b: String) -> bool: return a.right(15) < b.right(15))
	var mem = MemorySourceScript.new()
	for v in names:
		_copy(lib.source, mem, v)
	var total: int = mem.size_bytes()
	var newest: String = names[-1]
	mem.remove_volume(newest)
	var rest: int = mem.size_bytes()
	check(rest > 0 and rest < total, "size_bytes counts sweeps")
	mem.budget_bytes = total - rest  # room for the newest alone
	_copy(lib.source, mem, newest)
	check_eq(mem.names(), PackedStringArray([newest]), "older volumes evicted")
	check_eq(mem.size_bytes(), total - rest, "bytes after eviction")
	mem.budget_bytes = 1
	_copy(lib.source, mem, newest)
	check_eq(mem.names(), PackedStringArray([newest]), "the added volume stays")


## With a window, eviction takes volumes outside it first (oldest first), then the oldest inside
## it, never the one just added; an open-ended window (live) keeps later scans inside.
func test_memory_window_eviction() -> void:
	var src: String = lib.volumes[0]
	var a := "KTST_20130520_193000"
	var b := "KTST_20130520_200000"
	var c := "KTST_20260923_110000"
	var d := "KTST_20260923_110500"
	var e := "KTST_20260923_111000"
	var mem = MemorySourceScript.new()
	_copy(lib.source, mem, src, a)
	var one: int = mem.size_bytes()
	if not check(one > 0, "fixture volume has sweeps"):
		return
	mem.remove_volume(a)
	mem.budget_bytes = 2 * one
	mem.set_window(RadarLibrary.unix_of(a), RadarLibrary.unix_of("KTST_20130520_204500"))
	for n in [a, b, c]:
		_copy(lib.source, mem, src, n)
	check_eq(_sorted(mem.names()), [b, c], "only window volumes to evict: the oldest goes")
	_copy(lib.source, mem, src, d)
	check_eq(_sorted(mem.names()), [b, d], "outside the window goes before inside")
	mem.budget_bytes = one
	_copy(lib.source, mem, src, e)
	check_eq(_sorted(mem.names()), [e], "inside too when still over; the added volume stays")
	mem.budget_bytes = 2 * one
	mem.set_window(RadarLibrary.unix_of(c), MemorySourceScript.OPEN_END)
	_copy(lib.source, mem, src, a)
	_copy(lib.source, mem, src, "KTST_20260923_120000")
	check_eq(
		_sorted(mem.names()), [e, "KTST_20260923_120000"], "open-ended window keeps later scans"
	)
	mem.clear_window()
	_copy(lib.source, mem, src, a)
	check_eq(_sorted(mem.names()), [a, "KTST_20260923_120000"], "no window: oldest first")


static func _sorted(names: PackedStringArray) -> Array:
	var out := Array(names)
	out.sort()
	return out


static func _copy(from: VolumeSource, to, name: String, as_name := "") -> void:
	var text := from.read_meta(name)
	var files := {}
	for sw in (JSON.parse_string(text) as Dictionary)["sweeps"]:
		for fd in sw["fields"].values():
			files[fd["file"]] = from.read_file(name, fd["file"])
	to.add_volume(as_name if as_name else name, text, files)
