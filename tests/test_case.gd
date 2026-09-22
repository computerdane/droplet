extends RefCounted
## Base for tests/unit/test_*.gd, run by tests/run.gd. Every method whose name starts with
## `test_` is one test; it fails if any check() inside it failed.
##
## `lib` indexes the volume root the runner was pointed at (the synthetic fixtures by
## default); `fixtures` is true then, so tests can assert exact facts about the fixture set
## and skip those assertions on real data.

var lib  # RadarLibrary
var fixtures := false
var _failures := PackedStringArray()


func check(ok: bool, what: String) -> bool:
	if not ok:
		_failures.append(what)
	return ok


## Equality check that prints both sides on failure.
func check_eq(got: Variant, want: Variant, what: String) -> bool:
	return check(got == want, "%s: got %s, want %s" % [what, got, want])


func note(msg: String) -> void:
	print("      ", msg)


func take_failures() -> PackedStringArray:
	var out := _failures
	_failures = PackedStringArray()
	return out
