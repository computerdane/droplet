extends SceneTree
## Godot unit tests: godot --headless --path . --script res://tests/run.gd [-- key=value ...]
## Runs every test_* method of every tests/unit/test_*.gd against the synthetic fixture
## volumes (`nexrad synth` writes them). Options:
##   volumes=res://data/volumes  run against another library root (e.g. real data)
##   only=readout                only tests whose file or method name contains this
## Exits 1 if any test failed or the volume root is empty.
## The tests run on the first frame, once the root is in the tree, so a test can add the main
## scene to it (test_app_window.gd) and have it readied.

const RadarLibraryScript := preload("res://scripts/radar_library.gd")
const DirSourceScript := preload("res://scripts/dir_source.gd")
const FIXTURE_ROOT := "res://tests/fixtures/volumes"
const UNIT_DIR := "res://tests/unit"

var _root := FIXTURE_ROOT
var _only := ""
var _lib  # RadarLibrary


func _initialize() -> void:
	var opts := {}
	for a in OS.get_cmdline_user_args():
		if "=" in a:
			opts[a.get_slice("=", 0)] = a.get_slice("=", 1)
	_root = opts.get("volumes", FIXTURE_ROOT)
	_only = opts.get("only", "")
	_lib = RadarLibraryScript.new(DirSourceScript.new(_root))
	print("volumes: %d under %s  sites: %s" % [_lib.volumes.size(), _root, _lib.sites()])
	if _lib.volumes.is_empty():
		push_error(
			(
				"no volumes under %s%s"
				% [_root, " (run: nexrad synth)" if _root == FIXTURE_ROOT else ""]
			)
		)
		quit(1)


func _process(_delta: float) -> bool:
	var root := _root
	var only := _only
	var lib = _lib
	var passed := 0
	var failed := PackedStringArray()
	for file in _test_files():
		var script: GDScript = load(UNIT_DIR.path_join(file))
		# A parse error leaves a script without methods: count it, or the file would silently pass.
		if script == null or not script.can_instantiate():
			failed.append("%s: does not load" % file)
			print("%s\n  FAIL  does not load" % file)
			continue
		var methods := PackedStringArray()
		for m in script.get_script_method_list():
			var name: String = m["name"]
			if name.begins_with("test_") and (only.is_empty() or only in file or only in name):
				methods.append(name)
		if methods.is_empty():
			continue
		print(file)
		for name in methods:
			var t = script.new()
			t.lib = lib
			t.fixtures = root == FIXTURE_ROOT
			var t0 := Time.get_ticks_msec()
			t.call(name)
			var errors: PackedStringArray = t.take_failures()
			var ms := Time.get_ticks_msec() - t0
			if errors.is_empty():
				passed += 1
				print("  ok    %s (%d ms)" % [name, ms])
			else:
				failed.append("%s:%s" % [file, name])
				print("  FAIL  %s (%d ms)" % [name, ms])
				for e in errors:
					print("        - ", e)
	print("\n%d passed, %d failed" % [passed, failed.size()])
	if not failed.is_empty():
		push_error("failed: " + ", ".join(failed))
	quit(1 if not failed.is_empty() or passed == 0 else 0)
	return true


func _test_files() -> PackedStringArray:
	var out := PackedStringArray()
	for f in DirAccess.get_files_at(UNIT_DIR):
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(f)
	out.sort()
	return out
