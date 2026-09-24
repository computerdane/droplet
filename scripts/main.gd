extends Node
## Controller: browsing state, the time window, playback, live following, and view/HUD updates.
##
## The app shows one time window (`window`, a TimeWindow): the frames of every site are the
## scans inside it, so the slider, playback, loop export, mosaic neighbours and prefetch never
## reach outside. Live is a window covering the last 60 min that rolls with the clock and
## follows the newest scan, even as older backfill arrives; L turns it off by freezing the
## window where it is (the loop on screen stays), and on again with a fresh live window of the
## same span. The playback bar names the window; on the desktop it goes to data/window.json
## (on every change and hourly) for `nexrad prune`. Frames are time ordered per site; playback
## loops within a sequence (gaps ≤30 min). Elevation persists across frames.
##
## Command-line options (after `--`): site=KTLX time=20130520_200359 field=VEL elev=0.5
## live=0|1 play=0|1 fps=8 zoom=2 pan=-15,5 (2D centre, km east,north) view=2d|3d yaw=30
## pitch=25 dist=400 exag=4 isolate=0|1|2 threshold=20 render=cones|volume density=0.05
## mosaic=0|1 prefetch=0|1 ui_scale=1.25 (multiplies the automatic UI scale, see _fit_ui_scale)
## section=ax,ay,bx,by (cross-section A -> B, km east,north of the radar)
## srm=240,10 (storm-relative velocity, storm moving from 240 degrees at 10 m/s) or srm=auto
## (storm motion from the VAD profile, see _auto_storm) winds=0|1 (hodograph panel)
## warnings=0|1 (NWS warning polygons, from the IEM archive) outlook=0|1 (SPC day 1 outlook)
## cells=0|1 (storm cells) vwp=0|1 (VAD winds over the loop as barbs) hover=x,y (pin the
## hover readout to that canvas point, for screenshots; hover=0 turns the readout off)
## basemap=0 (no basemap; or basemap=<dir>) volumes=res://tests/fixtures/volumes (DirSource
## root; default res://data/volumes) fetch=latest|live|2013-05-20T20:00Z|<from>/<to> (start a
## fetch job for site=, default KTLX; see AppOptions) event=moore2013 (a notable event's
## loop, see Events) window=live|live:<minutes>|<from>/<to> (the time window; without it fetch=,
## event= and time= (± 30 min) set it, else live: TimeWindow.from_options) keys=all (the key
## hint expanded, as H does)
##
## On web the options come from the page's query string instead (?site=KTLX&time=...).
## With no explicit site, time or fetch the app opens on NOAA's live US composite. Fetches
## follow the window (Fetcher.start_view, stop_outside): in live mode picking a site (or L) fetches
## its live window and follows it (desktop: its mosaic neighbours too), other sites' followers stop;
## a fixed window never fetches by itself (F does), and changing the window stops jobs outside it.
## Readouts use sweep files; loop and mosaic volumes preload via VolumeCache.

const LIVE_RESCAN_SEC := 3.0
## data/window.json is rewritten this often while nothing changes (prune ignores a stale file).
const WINDOW_HEARTBEAT_SEC := 3600.0
const OVERVIEW_OVERLAY_REFRESH_SEC := 60.0
## Automatic storm motion may come from a volume (any site) up to this far away in time.
const AUTO_STORM_MAX_SEC := 60 * 60
const VELOCITY_FIELDS := ["VEL", "DVEL"]
## Share of the cache budget that loop frames ahead of the playhead may fill.
const PRELOAD_BUDGET_FRACTION := 0.8
## Web: reserve most of the 2 GB wasm heap for ten recent full scans plus the growing
## partial (KTLX VCP 35 is ~120 MiB/scan), leaving room for textures and decode buffers.
const WEB_CACHE_BUDGET_BYTES := 192 << 20
const WEB_MEMORY_BUDGET_BYTES := 1400 << 20
const FIELD_KEYS := {
	KEY_1: "REF",
	KEY_2: "VEL",
	KEY_3: "SW",
	KEY_4: "ZDR",
	KEY_5: "PHI",
	KEY_6: "RHO",
	KEY_7: "CFP",
	KEY_8: "DVEL",
}
var library := RadarLibrary.new()
var fetcher := Fetcher.new()
var overlays := Overlays.new()  # warnings and storm cells over the 2D view
var loop_export := LoopExport.new()
var cache := VolumeCache.new(library.source)
var national: NationalComposite
var overview_overlay_timer := Timer.new()
var overview := false  # national MRMS image until the user picks a radar
var site := ""
var window: TimeWindow  # the one time window every site's frames lie in
var live_minutes := TimeWindow.DEFAULT_LIVE_MIN  # the live window's span (window=live:<minutes>)
var frames: Array[String] = []  # volume names for `site` inside `window`, ascending time
var frame := -1
var volume: RadarVolume
var sweep_index := -1  # sweep shown, resolved from field + target_elev
var field_name := "REF"
var target_elev := 0.5
var live := true  # follow-latest; window.live may stay true while browsing
var playing := false
var fps := 4.0
var view_is_3d := false
var mosaic := false
var prefetch := true  # read upcoming loop frames in the background
var section_on := false  # cross-section mode: line in the 2D view, panel in the HUD
var srm_on := false  # storm-relative velocity
var storm_from_deg := 240.0  # meteorological: direction the storm moves from
var storm_speed := 10.0  # m/s
var srm_auto := true  # storm motion from the VAD profile when there is one, else manual
var winds_shown := false  # hodograph panel
var vwp_shown := false  # wind profile over the loop
var ui_scale := 1.0  # user factor on top of the automatic UI scale
var _auto_storm: Dictionary = {}  # RadarLibrary.storm_motion_near() for the current volume
var _neighbors: Array = []  # mosaic entries, see Mosaic.neighbors()
var _others := PackedVector2Array()  # neighbours in the selected site's frame
var _site_lonlat := Vector2.INF  # site the views' basemaps are centred on
var _mouse_in_window := true
var _hover_pin := Vector2.INF  # hover= option: readout at this canvas point, not the mouse
var _hover_off := false  # hover=0: no readout (Xvfb leaves the pointer mid-screen)
var _readout_key: Array = []  # inputs of the readout on screen, see _update_readout
var _tracks := RotationTracks.Loops.new()  # while the rotation tracks are on screen
var _window_file := ""  # data/window.json for prune, when this app manages the data root
var _user_moves := 0  # times the user moved the view by hand; a fetch follows only until then
var _window_timer := Timer.new()  # its heartbeat

@onready var view_2d: PpiView = $View2D
@onready var view_3d: VolumeView3D = $View3D
@onready var hud: Hud = $UI/Hud
@onready var live_timer: Timer = $LiveTimer
@onready var play_timer: Timer = $PlayTimer


func _ready() -> void:
	live_timer.wait_time = LIVE_RESCAN_SEC
	live_timer.timeout.connect(_on_live_tick)
	play_timer.one_shot = true
	play_timer.timeout.connect(_on_play_tick)
	view_2d.view_changed.connect(_update_info)
	view_2d.site_clicked.connect(_pick_site)
	view_2d.section_changed.connect(_update_section)
	view_3d.camera.moved.connect(_update_info)
	add_child(fetcher)
	add_child(overlays)
	overview_overlay_timer.wait_time = OVERVIEW_OVERLAY_REFRESH_SEC
	overview_overlay_timer.timeout.connect(_refresh_overlays)
	add_child(overview_overlay_timer)
	add_child(loop_export)
	_window_timer.wait_time = WINDOW_HEARTBEAT_SEC
	_window_timer.timeout.connect(_write_window)
	add_child(_window_timer)
	_window_timer.start()
	overlays.changed.connect(_refresh_overlays)
	fetcher.job_updated.connect(_on_job_updated)
	fetcher.job_finished.connect(_on_job_finished)
	fetcher.volume_received.connect(_on_volume_received)
	fetcher.volume_written.connect(_on_volume_written)
	_connect_hud()
	hud.overview_requested.connect(_show_overview)
	get_window().mouse_entered.connect(func() -> void: _mouse_in_window = true)
	get_window().mouse_exited.connect(func() -> void: _mouse_in_window = false)

	var opts := AppOptions.parse()
	window = TimeWindow.from_options(opts)
	live = window.live
	if live:
		live_minutes = window.span_sec / 60
	overview = not (
		opts.has("site")
		or opts.has("time")
		or opts.has("event")
		or opts.has("fetch")
		or opts.has("window")
		or opts.has("view")
		or opts.has("volumes")
	)
	national = NationalComposite.new()
	national.visible = overview
	view_2d.add_child(national)
	view_2d.move_child(national, 0)
	view_2d.set_sites(RadarSites.ids())
	if opts.has("volumes"):
		_set_source(DirSource.new(opts["volumes"]))
	elif fetcher.web:
		_set_source(MemorySource.new(WEB_MEMORY_BUDGET_BYTES), WEB_CACHE_BUDGET_BYTES)
	else:  # the data root nexrad prunes: tell it the window
		_window_file = AppOptions.data_path("window.json")
	hud.set_window(window.label())
	_write_window()
	ui_scale = clampf(float(opts.get("ui_scale", ui_scale)), 0.5, 4.0)
	get_window().size_changed.connect(_fit_ui_scale)
	_fit_ui_scale()
	field_name = opts.get("field", field_name).to_upper()
	target_elev = float(opts.get("elev", target_elev))
	fps = float(opts.get("fps", fps))
	if opts.has("zoom"):
		view_2d.set_zoom(float(opts["zoom"]))
	if opts.has("pan"):
		var p: PackedFloat64Array = opts["pan"].split_floats(",")
		view_2d.cam.position = Vector2(p[0], -p[1])
	AppOptions.apply_3d(opts, view_3d, field_name)
	mosaic = opts.get("mosaic", "0") == "1"
	if opts.get("srm", "") == "auto":
		srm_on = true
	elif opts.has("srm"):
		var m: PackedFloat64Array = opts["srm"].split_floats(",")
		if m.size() == 2:
			storm_from_deg = m[0]
			storm_speed = m[1]
			srm_on = true
			srm_auto = false
	overlays.setup(hud, opts)
	winds_shown = opts.get("winds", "0") == "1"
	vwp_shown = opts.get("vwp", "0") == "1"
	hud.hint.expanded = opts.get("keys", "") == "all"
	if opts.get("hover", "") == "0":
		_hover_off = true
	elif opts.has("hover"):
		var h: PackedFloat64Array = opts["hover"].split_floats(",")
		_hover_pin = Vector2(h[0], h[1])
	if opts.has("section"):
		var s: PackedFloat64Array = opts["section"].split_floats(",")
		if s.size() == 4:
			view_2d.set_section(Vector2(s[0], -s[1]), Vector2(s[2], -s[3]))
			_set_section_on(true)
	prefetch = opts.get("prefetch", "1") == "1"
	_set_view_3d(opts.get("view", "2d") == "3d")
	if overview:
		_show_overview()
	else:
		var sites := library.sites()
		var want_site: String = opts.get("site", "").to_upper()
		var event := Events.find(opts.get("event", ""))
		# An event's site shows even before its scans exist (its fetch starts below), not the
		# site last fetched.
		var pick := Events.startup_site(event, want_site, sites)
		_select_site(pick if not pick.is_empty() else library.latest_site(window))
		if opts.has("time"):
			# The in-window scan nearest time= (an event's peak); with none, no frame until the
			# event's own scans arrive (the site's other days are outside the window).
			_go_to(RadarLibrary.nearest_in_time(frames, TimeWindow.parse_time(opts["time"])))
		_set_live(opts.get("live", "1" if live else "0") == "1")
		_set_playing(opts.get("play", "0") == "1")
		AppOptions.start_fetch(opts, fetcher, window)
	loop_export.setup(self, opts)


func _process(_delta: float) -> void:
	cache.poll()
	_update_readout()


func _connect_hud() -> void:
	hud.play_toggled.connect(func() -> void: _set_playing(not playing))
	hud.step_requested.connect(_step)
	hud.tilt_step_requested.connect(_step_tilt)
	hud.scrubbed.connect(
		func(i: int) -> void:
			_moved()
			_set_playing(false)
			_go_to(_sequence().x + i)
	)
	hud.speed_selected.connect(_set_fps)
	hud.live_toggled.connect(_toggle_live)
	hud.site_selected.connect(_pick_site)
	hud.field_selected.connect(_set_field)
	hud.view_toggled.connect(func() -> void: _set_view_3d(not view_is_3d))
	hud.mosaic_toggled.connect(_toggle_mosaic)
	hud.section_toggled.connect(func() -> void: _set_section_on(not section_on))
	hud.srm_toggled.connect(_toggle_srm)
	hud.srm_auto_toggled.connect(_toggle_srm_auto)
	hud.winds_toggled.connect(_toggle_winds)
	hud.vwp_toggled.connect(_toggle_vwp)
	hud.vwp.frame_picked.connect(_pick_frame)
	hud.fetch_toggled.connect(_toggle_fetch_panel)
	hud.fetch_panel.update_requested.connect(
		func(s: String, at: String, from: String, to: String) -> void:
			var w := TimeWindow.of_request(at, from, to, live_minutes)
			if w != null:  # else not a window (the panel says so): no job outside the window
				_open(s, w)
				_fetch_live()
				fetcher.start_update(s, at, from, to)
	)
	hud.fetch_panel.live_requested.connect(
		func(s: String) -> void:
			_open(s, TimeWindow.live_window(live_minutes))
			_fetch_live()
	)
	hud.fetch_panel.stop_requested.connect(fetcher.stop_all)
	hud.fetch_panel.event_requested.connect(
		func(id: String) -> void:
			var event := Events.find(id)
			_open(event["site"], TimeWindow.of_event(event))
			Events.start(event, fetcher, window)
	)
	if not fetcher.can_live:
		hud.fetch_panel.disable_live("Live needs a cross-origin isolated page (COOP/COEP headers)")
	hud.srm_changed.connect(_adjust_storm)


func _fit_ui_scale() -> void:
	hud.fit_ui_scale(ui_scale)


# --- state changes -------------------------------------------------------------------


func _select_site(s: String) -> void:
	if s.is_empty():
		return
	var was_overview := overview
	overview = false
	overview_overlay_timer.stop()
	national.set_overview(false)
	var t := RadarLibrary.unix_of(frames[frame]) if frame >= 0 else 0
	site = s
	window.tick()
	frames = library.for_site(site, window)
	hud.set_sites(library.sites(), site)
	if was_overview:
		view_2d.reset_camera()
		_update_hint()
	# Keep roughly the same moment in time when switching sites (no frame if the site has
	# no scan in the window).
	_go_to(RadarLibrary.nearest_in_time(frames, t) if t > 0 else frames.size() - 1)
	if volume == null:
		var ll := RadarSites.location(site)
		if ll != Vector2.INF:
			_site_lonlat = Vector2(ll.y, ll.x)
			view_2d.set_site(ll.x, ll.y)
		_update_info()


## Live mode fetches what it shows: the site's live window and, with the mosaic on (desktop), its
## nearest neighbours'; other sites' followers stop (Fetcher.start_view). Never a fixed window's.
func _fetch_live() -> void:
	if not overview:
		fetcher.start_view(site, window, mosaic)


func _open(s: String, w: TimeWindow) -> void:
	if site != s:
		_select_site(s)
	_set_window(w)


func _show_overview() -> void:
	overview = true
	site = ""
	fetcher.start_view(site, window)
	frames.clear()
	frame = -1
	volume = null
	_site_lonlat = Vector2(NationalComposite.CENTER.y, NationalComposite.CENTER.x)
	view_2d.set_site(NationalComposite.CENTER.x, NationalComposite.CENTER.y)
	view_2d.cam.position = Vector2.ZERO
	var size := get_viewport().get_visible_rect().size
	view_2d.set_zoom(minf(size.x / 5600.0, size.y / 3400.0))
	national.set_overview(true)
	overview_overlay_timer.start()
	_set_live(false)  # nothing to follow; the window stays as it is
	_set_playing(false)
	_set_view_3d(false)
	hud.set_sites(library.sites(), "")


## A negative index shows no frame (an event's site before its scans arrive).
func _go_to(i: int) -> void:
	if frames.is_empty() or i < 0:
		frame = -1
		volume = null
		_refresh()
		return
	frame = clampi(i, 0, frames.size() - 1)
	volume = cache.get_volume(frames[frame], true)
	_refresh()


## Steps within the current sequence; it stops at either end rather than running into
## another day's data (see _step_sequence).
func _step(delta: int) -> void:
	_moved()
	_set_playing(false)
	var seq := _sequence()
	_go_to(clampi(frame + delta, seq.x, seq.y))


## Jumps to the previous / next sequence: its last frame going back, its first going forward.
func _step_sequence(delta: int) -> void:
	var i := Playback.sequence_jump(frames, _sequence(), delta)
	if i < 0:
		return
	_moved()
	_set_playing(false)
	_go_to(i)


func _set_view_3d(on: bool) -> void:
	if overview and on:
		return
	view_is_3d = on
	view_2d.set_active(not on)
	view_3d.set_active(on)
	hud.set_view_3d(on)
	_update_hint()
	_refresh()


func _update_hint() -> void:
	var items := KeyHint.items_for(overview, view_is_3d, section_on)
	hud.set_hint(items[0], items[1])


func _set_section_on(on: bool) -> void:
	section_on = on
	view_2d.set_section_mode(on)
	_update_hint()
	_update_section()


func _toggle_mosaic() -> void:
	mosaic = not mosaic
	_fetch_live()  # the neighbours' followers start or stop
	_refresh()


func _toggle_srm() -> void:
	srm_on = not srm_on
	_refresh()


func _toggle_srm_auto() -> void:
	srm_auto = not srm_auto
	srm_on = srm_on or srm_auto
	_refresh()


func _toggle_winds() -> void:
	winds_shown = not winds_shown
	_refresh()


func _toggle_vwp() -> void:
	vwp_shown = not vwp_shown
	_refresh()


## A volume picked in the VWP: stop playback and live following and show it.
func _pick_frame(path: String) -> void:
	var i := frames.find(path)
	if i < 0:
		return
	_moved()
	_set_playing(false)
	_go_to(i)


## The user moved the view by hand: a running fetch stops taking it over (_follow_fetch).
func _moved() -> void:
	_user_moves += 1
	live = false  # suspend following, keeping the rolling window and its fetches


## A site the user picked (the HUD's list, S, a marker), even before any of its scans exist. In
## live mode it fetches the site's live window (_fetch_live); a fixed window shows what is cached.
func _pick_site(s: String) -> void:
	_moved()
	_select_site(s)
	if window.live:
		_set_live(true)
		_fetch_live()


## Nudging the storm motion switches to manual, starting from the automatic estimate.
func _adjust_storm(d_from_deg: float, d_speed: float) -> void:
	var cur := Hodograph.from_dir_speed(_storm_motion())
	storm_from_deg = cur.x
	storm_speed = cur.y
	srm_auto = false
	storm_from_deg = fposmod(storm_from_deg + d_from_deg, 360.0)
	storm_speed = clampf(storm_speed + d_speed, 0.0, 60.0)
	srm_on = true
	_refresh()


## Storm motion (m/s, +x east, +y north) to subtract, or zero when storm-relative display
## is off or the field is not a velocity.
func _storm_vector() -> Vector2:
	if not (srm_on and VELOCITY_FIELDS.has(field_name)):
		return Vector2.ZERO
	return _storm_motion()


## Storm motion in effect (m/s, +x east, +y north): the Bunkers right mover of the nearest
## VAD profile in auto mode, else the manual direction and speed. Estimates borrowed from
## another site are used unrotated (meridian convergence is a degree or two).
func _storm_motion() -> Vector2:
	if srm_auto and not _auto_storm.is_empty():
		var rm: Array = _auto_storm["storm_motion"]["right"]
		return Vector2(float(rm[0]), float(rm[1]))
	var heading := deg_to_rad(storm_from_deg + 180.0)  # direction it moves towards
	return Vector2(sin(heading), cos(heading)) * storm_speed


func _set_field(f: String) -> void:
	field_name = f
	_refresh()


## Field for the 3D view and the cross-section, which have no column products: REF instead.
func _volume_field() -> String:
	var two_d_only: bool = (
		field_name in RadarVolume.PRODUCTS or field_name == RotationTracks.VIEW_FIELD
	)
	return "REF" if two_d_only else field_name


## Field whose sweep the plan view shows (rotation tracks are built from ROT).
func _sweep_field() -> String:
	return RotationTracks.FIELD if field_name == RotationTracks.VIEW_FIELD else field_name


## Volumes of the loop around the current frame, oldest first.
func _loop_volumes() -> Array[RadarVolume]:
	if frame < 0:
		return []
	return Playback.loop_volumes(cache, frames, _sequence())


## 9 / 0: the first field of `cycle`, then the next one.
func _cycle_fields(cycle: Array) -> void:
	_set_field(cycle[(cycle.find(field_name) + 1) % cycle.size()])


func _step_tilt(delta: int) -> void:
	if volume == null or _volume_field() != field_name:
		return
	var tilts := volume.tilts(field_name)
	if tilts.is_empty():
		return
	var pos := maxi(tilts.find(sweep_index), 0)
	pos = clampi(pos + delta, 0, tilts.size() - 1)
	target_elev = volume.elevation(tilts[pos])
	_refresh()


## L: live on also fetches the live window (_fetch_live); off freezes it, stopping live jobs.
func _toggle_live() -> void:
	_set_live(not live)
	_fetch_live()


## Explicit Live activation resumes following; deactivation freezes the window.
## Manual navigation only suspends following (_moved), leaving the timer and fetches running.
func _set_live(on: bool) -> void:
	if overview:
		on = false
	elif on != window.live:
		_set_window(TimeWindow.live_window(live_minutes) if on else window.freeze())
		return
	live = on
	if on:
		_set_playing(false)
		live_timer.start()
		_on_live_tick()
	else:
		live_timer.stop()
	_update_playback()


## Switches to `w`: jobs fetching outside it stop (Fetcher.stop_outside), the site's frames are
## those inside it (the shown scan stays if it is, else the nearest inside shows), live following
## matches it, the HUD names it and prune learns it.
func _set_window(w: TimeWindow) -> void:
	_user_moves += 1
	window = w
	fetcher.stop_outside(w)
	if w.live:
		live_minutes = w.span_sec / 60
	hud.set_window(w.label())
	_write_window()
	if not overview and not site.is_empty():
		_rescan()
	_set_live(w.live)


## Tells the pruners the window: data/window.json for `nexrad prune` (TimeWindow.write_file;
## on the desktop when the app shows the data root it manages) on every change and as a
## heartbeat, and the web MemorySource's eviction (_window_to_source).
func _write_window() -> void:
	if not _window_file.is_empty() and not window.write_file(_window_file):
		push_warning("cannot write " + _window_file)
	_window_to_source()


## A MemorySource (web) evicts scans outside the window first once it has set_window (#41);
## a live window's start rolls, so this also runs when the window ticks (_refilter).
func _window_to_source() -> void:
	var mem := library.source as MemorySource
	if mem != null:
		mem.set_window(window.from, window.upper())


func _set_playing(on: bool) -> void:
	if overview and on:
		return
	playing = on
	if on:
		_moved()
		play_timer.start(1.0 / fps)
	else:
		play_timer.stop()
	_update_playback()


func _set_fps(v: float) -> void:
	fps = v
	_update_playback()


func _cycle_speed(delta: int) -> void:
	_set_fps(Playback.cycle_speed(fps, delta))


func _sequence() -> Vector2i:
	return RadarLibrary.sequence_bounds(frames, maxi(frame, 0))


# --- fetching from the UI --------------------------------------------------------


func _toggle_fetch_panel() -> void:
	hud.fetch_panel.toggle(site, RadarLibrary.unix_of(volume.name) if volume != null else 0, window)


## New volumes update the library; job notifications never resume suspended following.
func _on_job_updated(job: Fetcher.Job) -> void:
	var lines := PackedStringArray()
	for j in fetcher.jobs:
		lines.append(j.describe())
	hud.fetch_panel.set_jobs(lines)
	if not job.has_meta("moves"):  # its first report: it may follow until the user moves
		job.set_meta("moves", _user_moves)
	if job.volumes.size() != job.get_meta("seen", 0):
		job.set_meta("seen", job.volumes.size())
		_rescan()
	_update_info()


func _on_volume_received(name: String, volume_json: String, files: Dictionary) -> void:
	var mem := library.source as MemorySource
	if mem != null:
		mem.add_volume(name, volume_json, files)
		_on_volume_changed(name)


func _on_volume_written(name: String) -> void:
	var dir := library.source as DirSource
	if dir != null:
		dir.mark_updated(name)
		_on_volume_changed(name)


## Replace cached data and refresh any view that shows this name.
func _on_volume_changed(name: String) -> void:
	cache.invalidate(name)
	overlays.invalidate_volume(name)
	_tracks.invalidate_volume(name)
	_rescan()
	if _follow_fetch(name):
		return
	if volume != null and volume.name == name:
		_go_to(frame)
	elif (
		VolumeUpdatePolicy.shown_in_loop(name, volume, frames, frame)
		or (
			volume != null
			and mosaic
			and library.site_of(name) != site
			and window.contains(RadarLibrary.unix_of(name))
		)
	):
		_refresh()
	if window.live:
		_on_live_tick()


## An update's scans show as they arrive (oldest first) while the view is on its site, not
## live, not playing, and the user has not moved it by hand since the job started: each
## in-window scan nearer the fetch's target (an event's peak, the scan time it was asked for,
## else the window's end) takes over (Events.takes_over), so the launch that fetches an event
## ends on it even if the fetch does not finish cleanly. Scans outside the window are not in
## `frames` and never show.
func _follow_fetch(name: String) -> bool:
	if window.live or playing or site != RadarLibrary.site_of(name) or not frames.has(name):
		return false
	for job in fetcher.running_jobs():
		if job.stopped or job.kind != "update" or job.site != site:
			continue
		if job.get_meta("moves", -1) != _user_moves:
			continue
		var target: int = job.get_meta("jump_to", TimeWindow.parse_time(job.at))
		if target < 0:
			target = window.to
		if Events.takes_over(target, name, volume.name if volume != null else ""):
			_go_to(frames.find(name))
			return true
	return false


## A finished update jumps to the last volume it fetched (a notable event: to its peak). What
## it fetched must be visible: when that lies outside the window, the window becomes the job's
## range, else the half hour around it (fetch=latest from a radar quiet for over an hour). In
## live mode an update whose scans are in the live window (the newest scan, a live window's fetch
## where live cannot run) leaves live following, and its followers, on.
func _on_job_finished(job: Fetcher.Job) -> void:
	print("fetch: ", job.describe())  # the web smoke test waits for this line
	if job.kind != "update" or job.stopped or job.volumes.is_empty():
		return
	if overview or playing or job.site != site or job.get_meta("moves", -1) != _user_moves:
		return
	var t: int = job.get_meta("jump_to", RadarLibrary.unix_of(job.volumes[-1]))
	if window.live and (window.contains(t) or job.window != null and job.window.live):
		return
	if not window.contains(t):
		var range := TimeWindow.parse_option(job.from + "/" + job.to)  # null without a range
		_set_window(range if range != null else TimeWindow.around(t))
	_rescan()
	_set_live(false)
	_set_playing(false)
	if job.site != site:
		_select_site(job.site)
	var i := RadarLibrary.nearest_in_time(frames, t)
	if i >= 0:
		_go_to(i)


## Switches where volumes come from; drops everything loaded from the old source. Call before
## a site is selected (the frame on screen is not kept).
func _set_source(source: VolumeSource, budget_bytes := cache.budget_bytes) -> void:
	library = RadarLibrary.new(source)
	cache = VolumeCache.new(source, budget_bytes)


## Re-reads the volume source, keeping the frame on screen.
func _rescan() -> void:
	library.scan()
	hud.set_sites(library.sites(), site)
	_refilter()
	_update_playback()


## The site's frames inside the window (rolled forward first when live). The shown scan keeps
## its place; when it is no longer inside (the window changed or rolled on), the nearest scan
## inside shows, or none.
func _refilter() -> void:
	window.tick()
	_window_to_source()
	frames = library.for_site(site, window)
	if volume == null:
		if window.live and not frames.is_empty():
			_go_to(frames.size() - 1 if live else 0)
		return
	var i := frames.find(volume.name)
	if i >= 0:
		frame = i
	else:
		_go_to(RadarLibrary.nearest_in_time(frames, RadarLibrary.unix_of(volume.name)))


# --- timers --------------------------------------------------------------------------


## Rolls the live window on, re-reads the source and follows the newest scan inside it.
func _on_live_tick() -> void:
	library.scan()
	if overview:
		return
	if site.is_empty():
		_select_site(library.latest_site(window))
		return
	_refilter()
	if live and not frames.is_empty() and not playing:
		var target := VolumeUpdatePolicy.live_target(frames, volume, playing)
		if not target.is_empty():
			_go_to(frames.find(target))
	_update_playback()  # new frames join the loop on the next pass; old ones left it


func _on_play_tick() -> void:
	var seq := _sequence()
	var next := Playback.next_frame(frame, seq)
	_go_to(next)
	if playing:
		play_timer.start(Playback.frame_wait(next, seq, fps))


# --- presentation --------------------------------------------------------------------


func _refresh() -> void:
	var shown := _volume_field() if view_is_3d else _sweep_field()
	sweep_index = volume.tilt_near(shown, target_elev) if volume != null else -1
	if volume != null:
		var ll := Vector2(float(volume.meta["longitude"]), float(volume.meta["latitude"]))
		if ll != _site_lonlat:
			_site_lonlat = ll
			view_2d.set_site(ll.y, ll.x)
			view_3d.set_site(ll.y, ll.x)
	_neighbors = []
	if mosaic and volume != null:
		_neighbors = Mosaic.neighbors(library, cache, volume, shown, target_elev, window)
	_others = Mosaic.assign_others(_neighbors)
	var on_screen: Array = [volume.name] if volume != null else []
	for n in _neighbors:
		on_screen.append((n["volume"] as RadarVolume).name)
	cache.pin(on_screen)
	_auto_storm = (
		library.storm_motion_near(volume.name, AUTO_STORM_MAX_SEC) if volume != null else {}
	)
	var storm := _storm_vector()
	view_2d.storm_motion = storm
	view_3d.storm_motion = storm
	hud.section.storm_motion = storm
	if not (field_name == RotationTracks.VIEW_FIELD and not view_is_3d):
		_tracks.clear()
	if view_is_3d:
		view_3d.show_volume(volume, _volume_field(), target_elev, _neighbors, _others)
	elif field_name == RotationTracks.VIEW_FIELD:
		var loop := _loop_volumes()
		_tracks.add_to_neighbors(_neighbors, library, loop, window)
		view_2d.show_tracks(_tracks.of(loop), frame - _sequence().x + 1, _neighbors, _others)
	else:
		view_2d.show_sweep(volume, sweep_index, field_name, _neighbors, _others)
	hud.set_mosaic(mosaic, library.sites().size() > 1)
	var available: Array = []
	if volume != null:
		for i in volume.sweep_count():
			for f in volume.fields_of(i):
				if not available.has(f):
					available.append(f)
	if available.has(RotationTracks.FIELD):
		available.append(RotationTracks.VIEW_FIELD)
	hud.set_field(field_name, available, storm != Vector2.ZERO)
	hud.set_overview(overview)
	var motion := Hodograph.from_dir_speed(_storm_motion())
	hud.set_srm(
		VELOCITY_FIELDS.has(field_name),
		srm_on,
		srm_auto,
		not _auto_storm.is_empty(),
		motion.x,
		motion.y
	)
	_update_winds()
	_refresh_overlays()
	_update_vwp()
	_update_section()
	_update_info()
	_update_playback()
	_preload_ahead()
	_readout_key.clear()  # what is under the mouse may have changed


## Warnings and tracked cells for the frame on screen (Overlays).
func _refresh_overlays() -> void:
	overlays.library = library
	overlays.window = window
	var index := frame - _sequence().x
	overlays.update(view_2d, view_3d, volume, _loop_volumes(), index, _neighbors, overview)
	_readout_key.clear()
	_update_info()


## VAD profiles of every volume in the current loop.
func _update_vwp() -> void:
	hud.set_vwp_shown(vwp_shown)
	if not vwp_shown:
		return
	var seq := _sequence()
	var columns := Playback.vwp_columns(library, frames, seq) if frame >= 0 else []
	var title := "VWP  %s  (km ARL, barbs kt)" % site
	hud.vwp.show_profiles(columns, frame - seq.x, title)


func _update_winds() -> void:
	hud.set_winds_shown(winds_shown)
	if not winds_shown:
		return
	if volume == null:
		hud.hodograph.show_winds(null, null, Vector2.INF, "VAD winds", "")
		return
	var own := library.winds(volume.name)
	var motion = own.get("storm_motion")
	if motion == null and not _auto_storm.is_empty():
		motion = _auto_storm["storm_motion"]
	var title := "VAD winds  %s %s  (m/s)" % [volume.icao(), RadarLibrary.clock(volume.name)]
	var in_use := _storm_motion() if srm_on else Vector2.INF
	var source := InfoText.storm_source(self)
	hud.hodograph.show_winds(own.get("wind_profile"), motion, in_use, title, source)


## Readout of whatever is under the mouse: the section panel, the VWP, or the 2D view
## (value, range/bearing and beam height from the radar whose pixel it is, lat/lon).
## Recomputed only when its inputs change; _refresh() invalidates it.
func _update_readout() -> void:
	var mouse := get_viewport().get_mouse_position()
	var hovered := get_viewport().gui_get_hovered_control()
	if _hover_pin != Vector2.INF:
		mouse = _hover_pin
		hovered = null
		for c: Control in [hud.section, hud.vwp]:
			if c.is_visible_in_tree() and c.get_global_rect().has_point(mouse):
				hovered = c
	var world := view_2d.get_canvas_transform().affine_inverse() * mouse
	var screen := hovered != null or view_is_3d
	var cam3d: Variant = view_3d.camera.global_transform if view_is_3d else null
	var key: Array = [_mouse_in_window, hovered, mouse if screen else world, cam3d]
	if key == _readout_key:
		return
	_readout_key = key
	var text := ""
	var marker := Vector2.INF
	if _hover_off or (not _mouse_in_window and _hover_pin == Vector2.INF):
		pass
	elif overview and hovered == null:
		var station := view_2d.station_at(mouse)
		text = overlays.overview_readout(world, station)
	elif hovered == hud.section:
		var s := hud.section.sample_at(hud.section.get_global_transform().affine_inverse() * mouse)
		if not s.is_empty():
			text = s["text"]
			marker = view_2d.section_a.lerp(view_2d.section_b, s["t"])
	elif hovered == hud.vwp:
		text = hud.vwp.sample_at(hud.vwp.get_global_transform().affine_inverse() * mouse).get(
			"text", ""
		)
	elif hovered == null and not view_is_3d and volume != null:
		# The hodograph ignores the mouse, but the map under it is hidden.
		var hodo := hud.hodograph
		if not (hodo.visible and hodo.get_global_rect().has_point(mouse)):
			text = _readout_2d(world)
	elif hovered == null and volume != null:
		var ctx := {"field": _volume_field(), "site_lonlat": _site_lonlat, "overlays": overlays}
		text = Readout.volume_3d(view_3d.pick(mouse + Vector2(0.5, 0.5)), ctx)  # pixel centre
	view_2d.set_hover_marker(marker)
	hud.set_readout(text, hud.get_global_transform().affine_inverse() * mouse)


## Readout at a 2D view point (km, +x east, +y south of the selected radar), see Readout.
func _readout_2d(p: Vector2) -> String:
	var tracks: Array[RadarVolume] = []
	if field_name == RotationTracks.VIEW_FIELD:
		tracks = _loop_volumes()
	var ctx := {
		"volume": volume,
		"sweep": sweep_index,
		"field": field_name,
		"neighbors": _neighbors,
		"storm": _storm_vector(),
		"site_lonlat": _site_lonlat,
		"tracks": tracks,
		"n_tracks": frame - _sequence().x + 1,
		"overlays": overlays,
	}
	return Readout.plan_view(p, ctx)


func _update_section() -> void:
	_readout_key.clear()
	var shown := section_on and view_2d.has_section
	hud.set_section(section_on, shown)
	view_3d.overlay.set_section(shown, view_2d.section_a, view_2d.section_b)
	if shown:
		var a := view_2d.section_a
		hud.section.show_section(volume, _volume_field(), a, view_2d.section_b, _neighbors)


## Queues background reads of the frames after the current one, wrapping around the loop,
## with the textures the active view needs, until PRELOAD_BUDGET_FRACTION of the cache
## would be used. Mosaic neighbours of each frame are included.
func _preload_ahead() -> void:
	if volume == null or not prefetch:
		return
	var seq := _sequence()
	var n := seq.y - seq.x + 1
	var budget := int(cache.budget_bytes * PRELOAD_BUDGET_FRACTION)
	var need := VolumeCache.Need.NEAREST_TILT
	if view_is_3d:
		need = VolumeCache.Need.TILT_ARRAY if view_3d.volume_render else VolumeCache.Need.ALL_TILTS
	elif section_on and view_2d.has_section:
		need = VolumeCache.Need.ALL_TILTS
	var f := field_name if need == VolumeCache.Need.NEAREST_TILT else _volume_field()
	budget -= cache.prefetch(volume.name, f, target_elev, need)
	for nb in _neighbors:
		budget -= cache.prefetch(nb["volume"].name, f, target_elev, need)
	for k in range(1, n):
		if budget <= 0:
			break
		var path := frames[seq.x + (frame - seq.x + k) % n]
		budget -= cache.prefetch(path, f, target_elev, need)
		var t := RadarLibrary.unix_of(path)
		for nb in _neighbors:
			var other := Mosaic.path_near(library, nb["site"], t, window)
			if not other.is_empty():
				budget -= cache.prefetch(other, f, target_elev, need)


func _update_playback() -> void:
	if overview:
		hud.set_playback(false, false, 0, 0, "", fps)
		return
	var seq := _sequence()
	var t := ""
	if volume != null:
		t = volume.time_utc().replace("T", " ").left(19) + "Z"
	var count := seq.y - seq.x + 1 if frame >= 0 else 0
	hud.set_playback(playing, live, frame - seq.x, count, t, fps)


func _update_info() -> void:
	hud.set_info(InfoText.build(self))


# --- input ---------------------------------------------------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var e := event as InputEventKey
	# Key repeat only for stepping frames, so holding Left/Right scrubs through the loop.
	if e.echo and not (e.keycode in [KEY_LEFT, KEY_RIGHT] and not e.shift_pressed):
		return
	match e.keycode:
		KEY_SPACE:
			_set_playing(not playing)
		KEY_LEFT:
			if e.shift_pressed:
				_step_sequence(-1)
			else:
				_step(-1)
		KEY_RIGHT:
			if e.shift_pressed:
				_step_sequence(1)
			else:
				_step(1)
		KEY_HOME:
			_moved()
			_set_playing(false)
			_go_to(_sequence().x)
		KEY_END:
			_moved()
			_set_playing(false)
			_go_to(_sequence().y)
		KEY_UP:
			_step_tilt(1)
		KEY_DOWN:
			_step_tilt(-1)
		KEY_BRACKETLEFT:
			_cycle_speed(-1)
		KEY_BRACKETRIGHT:
			_cycle_speed(1)
		KEY_L:
			_toggle_live()
		KEY_S:  # the next cached site
			var sites := library.sites()
			if sites.size() > 1:
				_pick_site(sites[(sites.find(site) + 1) % sites.size()])
		KEY_R:
			if view_is_3d:
				view_3d.camera.reset()
			else:
				view_2d.reset_camera()
		KEY_M:
			_toggle_mosaic()
		KEY_V:
			_set_view_3d(not view_is_3d)
		KEY_X:
			_set_section_on(not section_on)
		KEY_T:
			_toggle_srm()
		KEY_W:
			_toggle_winds()
		KEY_P:
			_toggle_vwp()
		KEY_F:
			_toggle_fetch_panel()
		KEY_H:
			hud.toggle_hint()
		KEY_B:
			view_3d.volume_render = not view_3d.volume_render
			_refresh()
		KEY_MINUS:
			view_3d.adjust_density(-1)
			_refresh()
		KEY_EQUAL:
			view_3d.adjust_density(1)
			_refresh()
		KEY_I:
			view_3d.isolate = ((view_3d.isolate + 1) % ConeSet.Isolate.size()) as ConeSet.Isolate
			_refresh()
		KEY_COMMA:
			view_3d.adjust_threshold(_volume_field(), -1)
			_refresh()
		KEY_PERIOD:
			view_3d.adjust_threshold(_volume_field(), 1)
			_refresh()
		KEY_PAGEUP:
			view_3d.set_exaggeration(view_3d.exaggeration + 1.0)
			_update_info()
		KEY_PAGEDOWN:
			view_3d.set_exaggeration(view_3d.exaggeration - 1.0)
			_update_info()
		_:
			if FIELD_KEYS.has(e.keycode):
				_set_field(FIELD_KEYS[e.keycode])
			elif e.keycode == KEY_9:
				_cycle_fields(RadarVolume.PRODUCTS + [RotationTracks.VIEW_FIELD])
			elif e.keycode == KEY_0:
				_cycle_fields(["KDP", "AZSHR", "HCA"])
