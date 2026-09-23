class_name RotationTracks
extends RefCounted
## Rotation tracks: the low-level rotation product (ROT, nexrad/src/products.rs) of every
## volume of a loop as one Texture2DArray, so ppi_tracks.gdshader can take the maximum over the
## frames up to the playhead. Layers follow the loop's order and are padded to the widest grid.

const FIELD := "ROT"
## The pseudo-field that shows the tracks (a button next to the products).
const VIEW_FIELD := "TRACKS"
## Rotation below this (10⁻³ s⁻¹) is not drawn, so the tracks stand out.
const MIN_VALUE := 5.0

var names: Array[String] = []  # volumes in layer order
var texture: Texture2DArray
var first_gate_km := 0.0
var gate_spacing_km := 0.0
var width := 0


## Tracks for `vols` (a loop, oldest first); null if none of them has ROT. Volumes without it
## get an empty layer so layer k stays frame k.
static func build(vols: Array[RadarVolume]) -> RotationTracks:
	var images: Array[Image] = []
	var geometry := {}
	var w := 0
	for vol in vols:
		var i := vol.tilt_near(FIELD, 0.0)
		var img: Image = vol.read_image(i, FIELD) if i >= 0 else null
		if img != null:
			if img.get_height() != TiltArray.ROWS:
				img.resize(img.get_width(), TiltArray.ROWS, Image.INTERPOLATE_NEAREST)
			if geometry.is_empty():
				geometry = vol.sweep(i)["fields"][FIELD]
			w = maxi(w, img.get_width())
		images.append(img)
	if geometry.is_empty():
		return null
	var t := RotationTracks.new()
	for k in images.size():
		var img := images[k]
		if img == null or img.get_width() != w:
			var padded := Image.create_empty(w, TiltArray.ROWS, false, Image.FORMAT_RH)
			padded.fill(Color(RadarVolume.MISSING, 0, 0))
			if img != null:
				padded.blit_rect(img, Rect2i(0, 0, img.get_width(), TiltArray.ROWS), Vector2i.ZERO)
			images[k] = padded
		t.names.append(vols[k].name)
	t.texture = Texture2DArray.new()
	t.texture.create_from_images(images)
	t.width = w
	t.first_gate_km = float(geometry["first_gate_m"]) / 1000.0
	t.gate_spacing_km = float(geometry["gate_spacing_m"]) / 1000.0
	return t


## The track value at azimuth `az_deg`, ground range `r_km` over the first `n` volumes of
## `vols` (the CPU twin of the shader, for the readout), or MISSING.
static func value_at(vols: Array[RadarVolume], n: int, az_deg: float, r_km: float) -> float:
	var best := RadarVolume.MISSING
	for k in mini(n, vols.size()):
		var i := vols[k].tilt_near(FIELD, 0.0)
		if i >= 0:
			best = maxf(best, vols[k].value_at(i, FIELD, az_deg, r_km))
	return best if best >= MIN_VALUE else RadarVolume.MISSING


## The tracks on screen, rebuilt only when a loop's volumes change: the selected site's loop
## (of()) and each mosaic neighbour's volumes over the same span (add_to_neighbors()).
class Loops:
	extends RefCounted
	var _own: RotationTracks
	var _neighbors := {}  # site -> {names, vols, tracks}

	func clear() -> void:
		_own = null
		_neighbors.clear()

	## Tracks of `loop` (oldest first).
	func of(loop: Array[RadarVolume]) -> RotationTracks:
		var names: Array[String] = []
		for v in loop:
			names.append(v.name)
		if _own == null or _own.names != names:
			_own = RotationTracks.build(loop)
		return _own

	## Gives each of `neighbors` (Mosaic.neighbors entries) the tracks of its site's volumes
	## over `loop`'s span ("tracks", "tracks_vols") and how many of its frames reach the one it
	## shows ("n_tracks").
	func add_to_neighbors(
		neighbors: Array, library: RadarLibrary, loop: Array[RadarVolume]
	) -> void:
		if loop.is_empty():
			return
		var t0 := RadarLibrary.unix_of(loop[0].name) - Mosaic.MAX_SKEW_SEC
		var t1 := RadarLibrary.unix_of(loop[-1].name) + Mosaic.MAX_SKEW_SEC
		for n: Dictionary in neighbors:
			var site: String = n["site"]
			var names: Array[String] = []
			for name in library.for_site(site):
				var t := RadarLibrary.unix_of(name)
				if t >= t0 and t <= t1:
					names.append(name)
			var memo: Dictionary = _neighbors.get(site, {})
			if memo.get("names", []) != names:
				var vols: Array[RadarVolume] = []
				for name in names:
					var v := RadarVolume.open(library.source, name)
					if v != null:
						vols.append(v)
				memo = {"names": names, "vols": vols, "tracks": RotationTracks.build(vols)}
				_neighbors[site] = memo
			n["tracks"] = memo["tracks"]
			n["tracks_vols"] = memo["vols"]
			n["n_tracks"] = names.find((n["volume"] as RadarVolume).name) + 1
