extends "res://tests/test_case.gd"
## LoopExport's APNG encoder (no rendering).


func _png(color: Color) -> PackedByteArray:
	var img := Image.create(4, 3, false, Image.FORMAT_RGB8)
	img.fill(color)
	return img.save_png_to_buffer()


func _be32(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]


func test_apng_structure() -> void:
	check_eq(LoopExport.crc32("IEND".to_ascii_buffer()), 0xAE426082, "PNG CRC-32")
	var frames: Array[PackedByteArray] = [_png(Color.RED), _png(Color.BLUE), _png(Color.GREEN)]
	var apng := LoopExport.encode(frames, 5.0)
	var types := PackedStringArray()
	var seqs := PackedInt32Array()
	var pos := 8
	var crc_ok := true
	while pos + 12 <= apng.size():
		var n := _be32(apng, pos)
		var type := apng.slice(pos + 4, pos + 8).get_string_from_ascii()
		var data := apng.slice(pos + 8, pos + 8 + n)
		crc_ok = (
			crc_ok
			and LoopExport.crc32(apng.slice(pos + 4, pos + 8 + n)) == _be32(apng, pos + 8 + n)
		)
		types.append(type)
		if type == "acTL":
			check_eq(_be32(data, 0), 3, "acTL frame count")
			check_eq(_be32(data, 4), 0, "loops forever")
		if type == "fcTL" or type == "fdAT":
			seqs.append(_be32(data, 0))
		if type == "fcTL":
			check_eq([_be32(data, 4), _be32(data, 8)], [4, 3], "frame size")
			check_eq((data[20] << 8) | data[21], 200, "delay 200 ms at 5 fps")
		pos += 12 + n
	check_eq(pos, apng.size(), "chunks fill the file")
	check(crc_ok, "every chunk CRC matches")
	check_eq(types[0], "IHDR", "IHDR first")
	check_eq(types[1], "acTL", "then acTL")
	check_eq(types[types.size() - 1], "IEND", "IEND last")
	check_eq(types.count("fcTL"), 3, "one fcTL per frame")
	check(types.has("IDAT") and types.has("fdAT"), "first frame IDAT, later fdAT")
	var consecutive := true
	for i in seqs.size():
		consecutive = consecutive and seqs[i] == i
	check(consecutive, "sequence numbers 0..n-1")
	var first := Image.new()
	check_eq(first.load_png_from_buffer(apng), OK, "readable as a plain PNG (first frame)")
	check_eq(first.get_pixel(0, 0), Color.RED, "first frame")
