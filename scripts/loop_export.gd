class_name LoopExport
extends Node
## Saves the loop on screen as an animated PNG (APNG, which browsers and most image viewers
## play): every volume of the current sequence, rendered as displayed (view, field, overlays,
## HUD), at the loop speed. E or the HUD's Export button; desktop builds write
## data/exports/<first volume>_to_<last>.png, the web build hands the file to the browser.
## `export=<path>` exports once the view has settled at startup and quits (scripted use).
## Frames are captured from the viewport after it has drawn each volume, so it takes a
## moment per frame and the screen steps through the loop meanwhile.

signal finished(path: String)

const MAX_SIDE := 1600  # larger viewports (hi-dpi) are scaled down to keep the file sane
const SETTLE_FRAMES := 3  # drawn frames to wait after stepping, for lazy textures
const STARTUP_FRAMES := 30
const WARNINGS_WAIT_SEC := 10.0  # per frame, for a warnings fetch in flight

static var _crc_table := PackedInt64Array()

var running := false
var _main: Node


## `main` is main.gd (its _sequence/_go_to/_set_playing/_set_live, frames, fps, hud, site).
func setup(main: Node, opts: Dictionary) -> void:
	_main = main
	main.hud.export_requested.connect(run)
	if opts.has("export"):
		_export_at_startup.call_deferred(opts["export"])


func _export_at_startup(path: String) -> void:
	for i in STARTUP_FRAMES:
		await RenderingServer.frame_post_draw
	await run(path)
	get_tree().quit(0 if FileAccess.file_exists(path) else 1)


func _unhandled_key_input(event: InputEvent) -> void:
	var e := event as InputEventKey
	if e.pressed and not e.echo and e.keycode == KEY_E:
		run()
		get_viewport().set_input_as_handled()


## Exports the current sequence to `path` (default: see the class doc).
func run(path := "") -> void:
	var frames: Array[String] = _main.frames
	if running or frames.is_empty():
		return
	running = true
	var seq: Vector2i = _main._sequence()
	var keep: int = _main.frame
	var was_playing: bool = _main.playing
	_main._set_playing(false)
	_main._set_live(false)
	var pngs: Array[PackedByteArray] = []
	for i in range(seq.x, seq.y + 1):
		_main._go_to(i)
		for k in SETTLE_FRAMES:
			await RenderingServer.frame_post_draw
		var waited := 0.0
		while _main.overlays.warnings.busy() and waited < WARNINGS_WAIT_SEC:
			await get_tree().create_timer(0.1).timeout
			waited += 0.1
		if waited > 0.0:
			await RenderingServer.frame_post_draw
			await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var scale := float(MAX_SIDE) / maxf(img.get_width(), img.get_height())
		if scale < 1.0:
			img.resize(
				roundi(img.get_width() * scale),
				roundi(img.get_height() * scale),
				Image.INTERPOLATE_LANCZOS
			)
		pngs.append(img.save_png_to_buffer())
	_main._go_to(keep)
	_main._set_playing(was_playing)
	var bytes := encode(pngs, _main.fps)
	var name := "%s_to_%s.png" % [frames[seq.x], frames[seq.y].trim_prefix(str(_main.site) + "_")]
	if OS.has_feature("web") and path.is_empty():
		JavaScriptBridge.download_buffer(bytes, name, "image/png")
		path = name
	else:
		if path.is_empty():
			var dir := "user://exports" if OS.has_feature("template") else "res://data/exports"
			DirAccess.make_dir_recursive_absolute(dir)
			path = dir.path_join(name)
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_error("export: cannot write %s" % path)
			running = false
			return
		f.store_buffer(bytes)
		f.close()
		path = ProjectSettings.globalize_path(path)
	print("export: %d frames, %.1f MB -> %s" % [pngs.size(), bytes.size() / 1e6, path])
	_main.hud.notify("Saved %d frames to %s" % [pngs.size(), path])
	running = false
	finished.emit(path)


## An APNG of `pngs` (PNG files of equal size and format, as Image.save_png_to_buffer()
## writes them) shown `fps` frames per second, looping forever: the first frame's IHDR, an
## acTL, then per frame an fcTL and its image data (IDAT for the first, fdAT after).
static func encode(pngs: Array[PackedByteArray], fps: float) -> PackedByteArray:
	var out := PackedByteArray([137, 80, 78, 71, 13, 10, 26, 10])
	var seq := 0
	var delay_ms := clampi(roundi(1000.0 / maxf(fps, 0.01)), 1, 65535)
	for f in pngs.size():
		var chunks := _chunks(pngs[f])
		if f == 0:
			out.append_array(_chunk("IHDR", chunks[0][1]))
			out.append_array(_chunk("acTL", _be32(pngs.size()) + _be32(0)))
		var ihdr: PackedByteArray = chunks[0][1]
		var fctl := _be32(seq) + ihdr.slice(0, 8) + _be32(0) + _be32(0)
		fctl.append_array([delay_ms >> 8, delay_ms & 255, 1000 >> 8, 1000 & 255, 0, 0])
		out.append_array(_chunk("fcTL", fctl))
		seq += 1
		for c in chunks:
			if c[0] != "IDAT":
				continue
			if f == 0:
				out.append_array(_chunk("IDAT", c[1]))
			else:
				out.append_array(_chunk("fdAT", _be32(seq) + c[1]))
				seq += 1
	out.append_array(_chunk("IEND", PackedByteArray()))
	return out


## [[type, data], ...] of a PNG file, IHDR first.
static func _chunks(png: PackedByteArray) -> Array:
	var out := []
	var pos := 8
	while pos + 12 <= png.size():
		var n := (png[pos] << 24) | (png[pos + 1] << 16) | (png[pos + 2] << 8) | png[pos + 3]
		out.append(
			[png.slice(pos + 4, pos + 8).get_string_from_ascii(), png.slice(pos + 8, pos + 8 + n)]
		)
		pos += 12 + n
	return out


static func _chunk(type: String, data: PackedByteArray) -> PackedByteArray:
	var body := type.to_ascii_buffer() + data
	return _be32(data.size()) + body + _be32(crc32(body))


static func _be32(v: int) -> PackedByteArray:
	return PackedByteArray([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255])


## CRC-32 as PNG chunks use it (~30 ms/MB in GDScript).
static func crc32(data: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for n in 256:
			var t := n
			for k in 8:
				t = (0xEDB88320 ^ (t >> 1)) if t & 1 else (t >> 1)
			_crc_table[n] = t
	var c := 0xFFFFFFFF
	for b in data:
		c = _crc_table[(c ^ b) & 0xFF] ^ (c >> 8)
	return c ^ 0xFFFFFFFF
