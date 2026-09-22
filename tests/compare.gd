extends SceneTree
## Compares two PNGs for tests/golden.sh:
##   godot --headless --path . --script res://tests/compare.gd -- golden.png actual.png diff.png
## A pixel differs when any channel is off by more than CHANNEL_TOLERANCE (software rendering
## can still move an edge by a pixel between CPUs); the images match when at most
## MAX_DIFFERING of the pixels differ. On a mismatch diff.png shows the actual image dimmed
## with the differing pixels in magenta. Exits 0 on a match, 1 otherwise.

const CHANNEL_TOLERANCE := 24.0 / 255.0
const MAX_DIFFERING := 0.002


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		push_error("usage: compare.gd -- golden.png actual.png [diff.png]")
		quit(2)
		return
	var golden := Image.load_from_file(args[0])
	var actual := Image.load_from_file(args[1])
	if golden == null or actual == null:
		push_error("cannot read %s or %s" % [args[0], args[1]])
		quit(2)
		return
	if golden.get_size() != actual.get_size():
		print("size %s, golden %s" % [actual.get_size(), golden.get_size()])
		quit(1)
		return
	golden.convert(Image.FORMAT_RGB8)
	actual.convert(Image.FORMAT_RGB8)
	var diff := actual.duplicate() as Image
	var differing := 0
	for y in golden.get_height():
		for x in golden.get_width():
			var a := golden.get_pixel(x, y)
			var b := actual.get_pixel(x, y)
			var d := maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))
			if d > CHANNEL_TOLERANCE:
				differing += 1
				diff.set_pixel(x, y, Color.MAGENTA)
			else:
				diff.set_pixel(x, y, b.darkened(0.7))
	var share := float(differing) / (golden.get_width() * golden.get_height())
	var ok := share <= MAX_DIFFERING
	print("%s  %d pixels differ (%.3f%%)" % ["ok" if ok else "DIFF", differing, share * 100.0])
	if not ok and args.size() > 2:
		diff.save_png(args[2])
	quit(0 if ok else 1)
