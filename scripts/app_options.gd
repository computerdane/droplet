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
## fetch; an unqualified URL opens the national composite instead. On web, a permalink with
## time= fetches that scan, and site= alone starts live (latest if isolation is unavailable).
## event=<id> (see Events) fetches that event's loop instead.
static func start_fetch(opts: Dictionary, fetcher: Fetcher) -> void:
	if opts.has("event") and not opts.has("fetch") and not Events.find(opts["event"]).is_empty():
		Events.start(Events.find(opts["event"]), fetcher)
		return
	var what: String = opts.get("fetch", "")
	if what.is_empty() and fetcher.web:
		what = iso_of_name_time(opts["time"]) if opts.has("time") else "live"
	if what == "live" and not fetcher.can_live:
		what = "latest"
	if what.is_empty():
		return
	var site: String = opts.get("site", DEFAULT_FETCH_SITE).to_upper()
	if what == "live":
		fetcher.start_live(site)
	elif what == "latest":
		fetcher.start_update(site)
	elif "/" in what:
		fetcher.start_update(site, "", what.get_slice("/", 0), what.get_slice("/", 1))
	else:
		fetcher.start_update(site, what)


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
