class_name TimeWindow
extends RefCounted
## The app's one time window [from, to] (unix seconds, UTC): the scans every site's timeline,
## playback and fetches use (issue #37). Pure: nothing here reads the clock except the
## `now` defaults of live() and tick().
##
## A fixed window comes from event=, time= (± AROUND_SEC), a fetch range or window=<from>/<to>.
## A live window covers the last `span_sec` (default 60 min, the same for every site whatever its
## scan interval); tick(now) rolls it forward. As an option it is window=live or
## window=live:<minutes>.
##
## Scan names carry the volume *start* time, so a scan belongs to the window when it starts
## inside it: contains() is inclusive at both ends with no slack, as Events.frame_within was.
## A live window has no upper bound (a scan that starts after the last tick is still live).

const DEFAULT_LIVE_MIN := 60
const AROUND_SEC := 30 * 60  # time=T opens T ± 30 min, like the fetch panel's prefill

var live := false
var span_sec := 0  # live only: how far back from now the window reaches
var from := 0
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
	to = now if now >= 0 else int(Time.get_unix_time_from_system())
	from = to - span_sec


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


func iso_to() -> String:
	return Time.get_datetime_string_from_unix_time(to) + "Z"


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
## ISO as in fetch= (2013-05-20T19:30Z, seconds optional); from must not be after to.
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


## The window the app opens on for its options (AppOptions.parse): window= first, then
## event=, fetch=<from>/<to> (or fetch=<time>, ± AROUND_SEC), time=, else live. An option that
## does not parse is skipped.
static func from_options(opts: Dictionary) -> TimeWindow:
	var w := parse_option(opts.get("window", ""))
	if w != null:
		return w
	var event := Events.find(opts.get("event", ""))
	if not event.is_empty():
		return of_event(event)
	var what: String = opts.get("fetch", "")
	if "/" in what:
		var a := parse_time(what.get_slice("/", 0))
		var b := parse_time(what.get_slice("/", 1))
		if a >= 0 and b >= a:
			return fixed(a, b)
	elif parse_time(what) >= 0:
		return around(parse_time(what))
	var t := parse_time(opts.get("time", ""))
	if t >= 0:
		return around(t)
	return live_window()


## Unix time of 20130520_193000 (time=, volume names) or 2013-05-20T19:30[:00][Z], or -1.
static func parse_time(s: String) -> int:
	var re := RegEx.create_from_string(
		(
			"^(\\d{4})(?:(\\d{2})(\\d{2})_(\\d{2})(\\d{2})(\\d{2})"
			+ "|-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2})(?::(\\d{2}))?Z?)$"
		)
	)
	var m := re.search(s)
	if m == null:
		return -1
	var iso := m.get_string(2).is_empty()
	var g := func(compact: int, dashed: int) -> int:
		return m.get_string(dashed if iso else compact).to_int()
	var dt := {
		"year": m.get_string(1).to_int(),
		"month": g.call(2, 7),
		"day": g.call(3, 8),
		"hour": g.call(4, 9),
		"minute": g.call(5, 10),
		"second": g.call(6, 11),
	}
	if dt["month"] < 1 or dt["month"] > 12 or dt["day"] < 1 or dt["day"] > _days_in(dt):
		return -1
	if dt["hour"] > 23 or dt["minute"] > 59 or dt["second"] > 59:
		return -1
	return Time.get_unix_time_from_datetime_dict(dt)


static func _days_in(dt: Dictionary) -> int:
	var y: int = dt["year"]
	if dt["month"] == 2:
		return 29 if (y % 4 == 0 and y % 100 != 0) or y % 400 == 0 else 28
	return 30 if dt["month"] in [4, 6, 9, 11] else 31


## 20130520_193000, as in time= and volume names.
static func _name_time(unix: int) -> String:
	var s := Time.get_datetime_string_from_unix_time(unix)
	return s.replace("-", "").replace(":", "").replace("T", "_")
