class_name AppOptions
## The app's key=value options (listed in main.gd's header): the command line after `--` on
## the desktop, the page's query string on web (?site=KTLX&time=20130520_200359).

const DEFAULT_FETCH_SITE := "KTLX"


static func parse() -> Dictionary:
	var args := OS.get_cmdline_user_args()
	if OS.has_feature("web"):
		var query := str(JavaScriptBridge.eval("location.search", true))
		args = PackedStringArray()
		for a in query.trim_prefix("?").split("&", false):
			args.append(a.uri_decode())
	var out := {}
	for a in args:
		if "=" in a:
			out[a.get_slice("=", 0)] = a.get_slice("=", 1)
	return out


## fetch=latest|live|<ISO time>|<ISO from>/<ISO to> starts that job for site= (default
## DEFAULT_FETCH_SITE). On web, where nothing is stored between visits, no fetch= means the
## volume at time= if given, else live, so every URL is a permalink.
static func start_fetch(opts: Dictionary, fetcher: Fetcher) -> void:
	var what: String = opts.get("fetch", "")
	if what.is_empty() and fetcher.web:
		what = iso_of_name_time(opts["time"]) if opts.has("time") else "live"
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
