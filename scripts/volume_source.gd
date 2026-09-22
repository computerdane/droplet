class_name VolumeSource
extends RefCounted
## Where decoded volumes come from (data format in CLAUDE.md). Volumes are named
## <ICAO>_<YYYYMMDD_HHMMSS>; each has a volume.json and one sNN_<FIELD>.bin per sweep/field.
## DirSource reads a directory (desktop); MemorySource holds volumes handed over whole, e.g.
## by the wasm decoder on web. RadarLibrary, RadarVolume and VolumeCache only go through here.
##
## read_file() and read_half() are called from WorkerThreadPool tasks (VolumeCache preloading)
## and must be thread-safe.


## Names of the volumes that have a volume.json, in any order.
func names() -> PackedStringArray:
	return PackedStringArray()


## volume.json of `name` as text, or "" if there is none.
func read_meta(_name: String) -> String:
	return ""


## Changes whenever volume.json of `name` is rewritten (live volumes grow); 0 if absent.
func version(_name: String) -> int:
	return 0


## Whole contents of one sweep file of `name`, or empty if missing.
func read_file(_name: String, _file: String) -> PackedByteArray:
	return PackedByteArray()


## The float16 at element `index` of a sweep file (the hover readout), NAN if unreadable.
func read_half(name: String, file: String, index: int) -> float:
	var bytes := read_file(name, file)
	if index < 0 or (index + 1) * 2 > bytes.size():
		return NAN
	return bytes.decode_half(index * 2)


## Where the volumes are, for messages ("No volumes in ...").
func describe() -> String:
	return "(no source)"
