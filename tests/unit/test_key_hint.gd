extends "res://tests/test_case.gd"
## The key hint's items, expansion and wrapping (KeyHint).


func test_collapsed_by_default() -> void:
	var h := KeyHint.new()
	var items := KeyHint.items_for(false, false, false)
	h.set_items(items[0], items[1])
	var collapsed := h.measure(2000.0)
	check(collapsed > 0.0, "shows something")
	check(not h.expanded, "collapsed")
	h.set_expanded(true)
	check(h.expanded, "expands")
	check(h.measure(2000.0) > collapsed, "expanded rows are taller")
	check(h.measure(400.0) > h.measure(2000.0), "narrower wraps into more rows")
	h.free()


func test_every_key_listed_when_expanded() -> void:
	for mode: Array in [[false, false], [true, false], [false, true]]:
		var items := KeyHint.items_for(false, mode[0], mode[1])
		for item: Variant in items[0]:
			check(item in items[1], "%s in the expanded list (3d=%s)" % [item, mode[0]])


func test_overview_has_no_toggle() -> void:
	var h := KeyHint.new()
	var items := KeyHint.items_for(true, false, false)
	check(items[1].is_empty(), "nothing more in the overview")
	h.set_items(items[0], items[1])
	h.set_expanded(true)
	check(not h.expanded, "cannot expand with nothing more")
	h.free()
