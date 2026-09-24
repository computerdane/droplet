class_name AppOptions
## The app's key=value options (listed in main.gd's header): the command line after `--` on
## the desktop, the page's query string on web (?site=KTLX&time=20130520_200359).
##
## The time window (TimeWindow.from_options): window=live|live:<minutes>|<from>/<to> is the
## canonical option; else fetch=, event= and time= each imply one (fetch= wins over event=, as
## in start_fetch), else the app opens live.

const DEFAULT_FETCH_SITE := "KTLX"

## Tests: when not empty, parse() reads these key=value args instead of the command line.
static var test_args := PackedStringArray()


## Native packages keep mutable data outside the read-only installed project.
static func data_path(child: String) -> String:
	var root := OS.get_environment("DROPLET_ROOT") if not OS.has_feature("web") else ""
	return (root.path_join("data") if not root.is_empty() else "res://data").path_join(child)


static func parse() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	if not test_args.is_empty():
		args = test_args
	elif OS.has_feature("web"):
		var query := str(JavaScriptBridge.eval("location.search", true))
		args = PackedStringArray()
		for a in query.trim_prefix("?").split("&", false):
			args.append(a.uri_decode())
	var out := {}
	for a in args:
		if "=" in a:
			out[a.get_slice("=", 0)] = a.get_slice("=", 1)
	var event := Events.find(out.get("event", ""))
	if not event.is_empty():  # site= and time= default to the event's
		out.get_or_add("site", event["site"])
		var peak := Time.get_datetime_string_from_unix_time(Events.unix(event["peak"]))
		out.get_or_add("time", peak.replace("-", "").replace(":", "").replace("T", "_"))
	return out


## fetch=latest|live|<ISO time>|<ISO from>/<ISO to> starts that job for site= (default
## DEFAULT_FETCH_SITE). Main only calls this on startup for an explicit site, time, event or
## fetch; an unqualified URL opens the national composite instead. event=<id> (see Events)
## fetches that event's loop instead. On web, a permalink with time= alone fetches that scan, and
## otherwise site= fetches the app's `window` (Fetcher.start_window: window=<from>/<to>'s scans).
## A live window is live mode's fetch (Fetcher.start_view), with mosaic=1 the neighbours' too
## (desktop only). Nothing starts outside `window` (window= wins over fetch= and event=, see
## TimeWindow.from_options): an event or a fetch= range is clipped to it (TimeWindow.clip) and
## skipped when they do not overlap, as is a fetch= time or latest outside it.
static func start_fetch(opts: Dictionary, fetcher: Fetcher, window: TimeWindow) -> void:
	var site: String = opts.get("site", DEFAULT_FETCH_SITE).to_upper()
	var what: String = opts.get("fetch", "")
	var event := Events.find(opts.get("event", ""))
	if what.is_empty() and not event.is_empty():
		Events.start(event, fetcher, window)
		return
	if what.is_empty() and fetcher.web:
		var at_time := opts.has("time") and not opts.has("window")
		what = iso_of_name_time(opts["time"]) if at_time else "view"
	if what == "live" and not fetcher.can_live:
		what = "latest"
	var range := TimeWindow.parse_option(what) if "/" in what else null
	if (what == "view" or what == "live") and window.live:
		fetcher.start_view(site, window, opts.get("mosaic", "0") == "1")
	elif what == "view":
		fetcher.start_window(site, window)
	elif what == "live":
		pass  # live following only in a live window
	elif range != null:
		if range.clip(window) != null:
			fetcher.start_window(site, range.clip(window))
	elif "/" in what:  # not a range nexrad takes: it says so
		fetcher.start_update(site, "", what.get_slice("/", 0), what.get_slice("/", 1))
	elif not what.is_empty():
		var at := what if what != "latest" else ""
		if Fetcher.within(window, "update", at):
			fetcher.start_update(site, at)


## 20130520_200359 (as in time= and volume names) -> 2013-05-20T20:03:59Z.
static func iso_of_name_time(t: String) -> String:
	return Time.get_datetime_string_from_unix_time(RadarLibrary.unix_of("X_" + t)) + "Z"


## The 3D view's options: yaw= pitch= dist= exag= isolate= render=cones|volume density=
## threshold= (of `field_name`).
static func apply_3d(opts: Dictionary, view_3d: VolumeView3D, field_name: String) -> void:
	var cam := view_3d.camera
	cam.set_view(
		float(opts.get("yaw", cam.yaw)),
		float(opts.get("pitch", cam.pitch)),
		float(opts.get("dist", cam.distance))
	)
	view_3d.set_exaggeration(float(opts.get("exag", view_3d.exaggeration)))
	view_3d.isolate = int(opts.get("isolate", view_3d.isolate)) as ConeSet.Isolate
	view_3d.volume_render = opts.get("render", "cones") == "volume"
	view_3d.density = float(opts.get("density", view_3d.density))
	if opts.has("threshold"):
		view_3d.thresholds[field_name] = float(opts["threshold"])
