class_name TimeWindow
extends RefCounted
## The app's one time window [from, to] (unix seconds, UTC): the scans every site's timeline,
## playback and fetches use (issue #37). Pure: nothing here reads the clock (clock()) except
## the `now` defaults of live_window(), tick(), freeze() and write_file().
##
## A fixed window comes from event=, time= (± AROUND_SEC), a fetch range or window=<from>/<to>.
## A live window covers the last `span_sec` (default 60 min, the same for every site whatever its
## scan interval); tick(now) rolls it forward. As an option it is window=live or
## window=live:<minutes>.
##
## Scan names carry the volume *start* time, so a scan belongs to the window when it starts
## inside it: contains() is inclusive at both ends with no slack (as #35's Events.frame_within
## was, which window filtering replaced). A live window has no upper bound (a scan that starts
## after the last tick is still live).
##
## The app writes the window to data/window.json (write_file) for `nexrad prune` to protect.

const DEFAULT_LIVE_MIN := 60
const AROUND_SEC := 30 * 60  # time=T opens T ± 30 min, like the fetch panel's prefill

## Tests: when >= 0, the clock tick(), live_window(), freeze() and write_file() read.
static var clock_override := -1
static var _compact_re: RegEx  # parse_time's, compiled once
static var _iso_re: RegEx

var live := false
var span_sec := 0  # live only: how far back from now the window reaches
var from := 0
## The end. A live window is open-ended: `to` is only its last tick (use upper()).
var to := 0


## The window [p_from, p_to] (a fetch range).
static func fixed(p_from: int, p_to: int) -> TimeWindow:
	var w := TimeWindow.new()
	w.from = p_from
	w.to = p_to
	return w


## `unix` ± `half` seconds (time=).
static func around(unix: int, half := AROUND_SEC) -> TimeWindow:
	return fixed(unix - half, unix + half)


## An event's loop, from its `from` to its `to` (see Events).
static func of_event(event: Dictionary) -> TimeWindow:
	return fixed(Events.unix(event["from"]), Events.unix(event["to"]))


## The last `minutes` up to `now` (default: the system clock).
static func live_window(minutes := DEFAULT_LIVE_MIN, now := -1) -> TimeWindow:
	var w := TimeWindow.new()
	w.live = true
	w.span_sec = minutes * 60
	w.tick(now)
	return w


## Rolls a live window forward to end at `now` (default: the system clock). Fixed windows
## stay put.
func tick(now := -1) -> void:
	if not live:
		return
	to = now if now >= 0 else clock()
	from = to - span_sec


## Unix seconds now (or clock_override, for tests).
static func clock() -> int:
	return clock_override if clock_override >= 0 else int(Time.get_unix_time_from_system())


## This window's extent as of `now`, fixed: what turning live off (L) leaves on the timeline.
## A fixed window comes back as an equal copy.
func freeze(now := -1) -> TimeWindow:
	if not live:
		return fixed(from, to)
	var t := now if now >= 0 else clock()
	return fixed(t - span_sec, t)


## The last scan start time inside the window, or -1 when it is open-ended (live): what a
## prune window or `nexrad --to` should use rather than `to`.
func upper() -> int:
	return -1 if live else to


func contains(unix: int) -> bool:
	return unix >= from and (live or unix <= to)


## The volume names in `names` whose scans start inside the window, in their order.
func filter(names: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for n in names:
		if contains(RadarLibrary.unix_of(n)):
			out.append(n)
	return out


func equals(other: TimeWindow) -> bool:
	if other == null or other.live != live:
		return false
	return span_sec == other.span_sec if live else from == other.from and to == other.to


## `nexrad update --from/--to` times (and the fetch panel's): 2013-05-20T19:30:00Z.
func iso_from() -> String:
	return Time.get_datetime_string_from_unix_time(from) + "Z"


## A live window's is only its last tick: use upper() for a bound (prune, --to).
func iso_to() -> String:
	return Time.get_datetime_string_from_unix_time(to) + "Z"


## Writes the window for `nexrad prune` (nexrad/src/prune.rs) to `path` atomically (a temp
## file renamed into place, so prune never reads a torn file), creating the directory:
## {"from": ISO, "to": ISO, "live": bool, "written": ISO}, ISO as iso_from(). A live window is
## written as its extent as of `now` (from = now - span, to = now); prune rolls it forward by
## itself. `written` is `now` too: prune ignores the file once it is a day old, so the app
## rewrites it on every change and hourly. False if it could not be written.
func write_file(path: String, now := -1) -> bool:
	var t := now if now >= 0 else clock()
	var w := freeze(t)
	var doc := {
		"from": w.iso_from(),
		"to": w.iso_to(),
		"live": live,
		"written": Time.get_datetime_string_from_unix_time(t) + "Z",
	}
	var abs_path := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var tmp := abs_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(doc) + "\n")
	f.close()
	return DirAccess.rename_absolute(tmp, abs_path) == OK


## For the HUD: "LIVE (last 60 min)", "2013-05-20 19:30–20:45Z", or both dates when the ends
## fall on different UTC days ("1999-05-03 22:30–1999-05-04 00:45Z").
func label() -> String:
	if live:
		return "LIVE (last %d min)" % floori(span_sec / 60.0)
	var a := Time.get_datetime_string_from_unix_time(from, true).left(16)
	var b := Time.get_datetime_string_from_unix_time(to, true).left(16)
	if a.left(10) == b.left(10):
		b = b.substr(11)
	return "%s–%sZ" % [a, b]


## The window= value: "live", "live:<minutes>" or "<from>/<to>" in time='s format
## (20130520_193000/20130520_204500).
func to_option() -> String:
	if live:
		var minutes := floori(span_sec / 60.0)
		return "live" if minutes == DEFAULT_LIVE_MIN else "live:%d" % minutes
	return "%s/%s" % [_name_time(from), _name_time(to)]


## A window= value, or null if it is not one. Times may be as in time= (20130520_193000) or
## ISO as anything parse_time takes (2013-05-20T19:30Z); from must not be after to.
static func parse_option(s: String) -> TimeWindow:
	if s == "live":
		return live_window()
	if s.begins_with("live:"):
		var m := s.trim_prefix("live:")
		if not m.is_valid_int() or m.to_int() <= 0:
			return null
		return live_window(m.to_int())
	var parts := s.split("/")
	if parts.size() != 2:
		return null
	var a := parse_time(parts[0])
	var b := parse_time(parts[1])
	if a < 0 or b < 0 or a > b:
		return null
	return fixed(a, b)


## The window the app opens on for its options (AppOptions.parse), in AppOptions.start_fetch's
## order: window=; else fetch= (<from>/<to> as is, <time> ± AROUND_SEC, live or latest the live
## window); else event=; else time= (± AROUND_SEC); else live. A value that does not parse is
## skipped (start_fetch would hand a bad fetch= to nexrad, which fails).
## fetch=latest opens the live window, but the newest scan may be older than it: stage B must
## widen or re-target the window to that scan once it arrives.
static func from_options(opts: Dictionary) -> TimeWindow:
	var w := parse_option(opts.get("window", ""))
	if w != null:
		return w
	var what: String = opts.get("fetch", "")
	if what == "live" or what == "latest":
		return live_window()
	if "/" in what:
		w = parse_option(what)
		if w != null:
			return w
	elif parse_time(what) >= 0:
		return around(parse_time(what))
	var event := Events.find(opts.get("event", ""))
	if not event.is_empty():
		return of_event(event)
	var t := parse_time(opts.get("time", ""))
	if t >= 0:
		return around(t)
	return live_window()


## Unix time of 20130520_193000 (time=, volume names) or of any ISO time nexrad's
## Utc::parse_iso takes (fetch=, --at/--from/--to): 2013-05-20, 2013-05-20T20Z, 2013-05-20 20:10,
## 2013-05-20T20:10:30.5z, 2013-05-20T15:10-05:00 (converted to UTC); fractional seconds are
## dropped. -1 if it is not one, including impossible dates (2013-02-30), which nexrad
## would roll over.
static func parse_time(s: String) -> int:
	if _compact_re == null:
		_compact_re = RegEx.create_from_string(
			"^(\\d{4})(\\d{2})(\\d{2})_(\\d{2})(\\d{2})(\\d{2})$"
		)
		_iso_re = RegEx.create_from_string(
			(
				"^(\\d{4})-(\\d{1,2})-(\\d{1,2})(?:[T ](?:(\\d{1,2})(?::(\\d{1,2})"
				+ "(?::(\\d{1,2}(?:\\.\\d*)?))?)?)?(?:([Zz])|([+-])(\\d{1,2})(?::(\\d{1,2}))?)?)?$"
			)
		)
	s = s.strip_edges()
	var m := _compact_re.search(s)
	var zone := 0  # seconds east of UTC
	if m == null:
		m = _iso_re.search(s)
		if m == null:
			return -1
		zone = (m.get_string(9).to_int() * 60 + m.get_string(10).to_int()) * 60
		if m.get_string(8) == "-":
			zone = -zone
		if m.get_string(9).to_int() > 23 or m.get_string(10).to_int() > 59:
			return -1
	var dt := {
		"year": m.get_string(1).to_int(),
		"month": m.get_string(2).to_int(),
		"day": m.get_string(3).to_int(),
		"hour": m.get_string(4).to_int(),
		"minute": m.get_string(5).to_int(),
		"second": 0,
	}
	var sec := m.get_string(6).to_float()  # up to 60.999: nexrad allows a leap second
	if dt["month"] < 1 or dt["month"] > 12 or dt["day"] < 1 or dt["day"] > _days_in(dt):
		return -1
	if dt["hour"] > 23 or dt["minute"] > 59 or sec >= 61.0:
		return -1
	var unix := Time.get_unix_time_from_datetime_dict(dt) + floori(sec) - zone
	return unix if unix >= 0 else -1


static func _days_in(dt: Dictionary) -> int:
	var y: int = dt["year"]
	if dt["month"] == 2:
		return 29 if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0 else 28
	return 30 if dt["month"] in [4, 6, 9, 11] else 31


## 20130520_193000, as in time= and volume names.
static func _name_time(unix: int) -> String:
	var s := Time.get_datetime_string_from_unix_time(unix)
	return s.replace("-", "").replace(":", "").replace("T", "_")
