class_name TiltArray
extends RefCounted
## All tilts of one field of a RadarVolume in a single Texture2DArray, for volume
## rendering (volume.gdshader). Layers follow tilts() order and are padded to the widest
## tilt (MISSING beyond each tilt's own gates) and to ROWS azimuth rows (1° tilts repeat
## each row). Cached per field in RadarVolume.tilt_arrays and counted in its texture_bytes.

const ROWS := 720

var texture: Texture2DArray
var elevations := PackedFloat32Array()
var first_gate_km := PackedFloat32Array()
var gate_spacing_km := PackedFloat32Array()
var n_gates := PackedFloat32Array()  # per layer; the texture is `width` gates wide
var width := 0
var max_range_km := 0.0


## The cached array for `field_name`, built on the calling (main) thread if needed.
static func of(vol: RadarVolume, field_name: String) -> TiltArray:
	if not vol.tilt_arrays.has(field_name):
		add(vol, field_name, build_images(vol, field_name))
	return vol.tilt_arrays.get(field_name)


## Padded layer Images. Touches no state, so VolumeCache can run it on a worker thread.
static func build_images(vol: RadarVolume, field_name: String) -> Array[Image]:
	var out: Array[Image] = []
	var tl := vol.tilts(field_name)
	var w := 0
	for i in tl:
		w = maxi(w, int(vol.sweep(i)["fields"][field_name]["n_gates"]))
	for i in tl:
		var img := vol.read_image(i, field_name)
		if img == null:
			return [] as Array[Image]
		if img.get_height() != ROWS:
			img.resize(img.get_width(), ROWS, Image.INTERPOLATE_NEAREST)
		if img.get_width() != w:
			var padded := Image.create_empty(w, ROWS, false, Image.FORMAT_RH)
			padded.fill(Color(RadarVolume.MISSING, 0, 0))
			padded.blit_rect(img, Rect2i(0, 0, img.get_width(), ROWS), Vector2i.ZERO)
			img = padded
		out.append(img)
	return out


## Uploads `images` from build_images() as the array for `field_name` (main thread).
static func add(vol: RadarVolume, field_name: String, images: Array[Image]) -> void:
	if vol.tilt_arrays.has(field_name) or images.is_empty():
		return
	var ta := TiltArray.new()
	ta.texture = Texture2DArray.new()
	ta.texture.create_from_images(images)
	ta.width = images[0].get_width()
	for i in vol.tilts(field_name):
		var f: Dictionary = vol.sweep(i)["fields"][field_name]
		ta.elevations.append(vol.elevation(i))
		ta.first_gate_km.append(float(f["first_gate_m"]) / 1000.0)
		ta.gate_spacing_km.append(float(f["gate_spacing_m"]) / 1000.0)
		ta.n_gates.append(float(f["n_gates"]))
		var reach: float = ta.first_gate_km[-1] + ta.n_gates[-1] * ta.gate_spacing_km[-1]
		ta.max_range_km = maxf(ta.max_range_km, reach)
	vol.tilt_arrays[field_name] = ta
	vol.texture_bytes += images.size() * images[0].get_data_size()
