extends Node
## Controller: owns browsing state (site, frame, field, elevation), playback and live
## following, and pushes it into the active view and the HUD.
##
## Frames are the volumes of the current site in time order. Playback loops over the
## sequence (run of volumes without a >30 min gap) containing the current frame. Live mode
## re-scans the library and jumps to the newest frame; while playing, new frames simply
## join the loop. The chosen elevation is kept across frames, so VCP changes and split cuts
## do not make the tilt jump around.
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
## loop, see Events)
##
## On web the options come from the page's query string instead (?site=KTLX&time=...), volumes
## live in memory (MemorySource, filled by the wasm worker through Fetcher), and a page with no
## fetch= fetches what the other options point at, so any URL is a permalink.
##
## Hovering the 2D view, the cross-section or the VWP shows a readout of the value under
## the mouse next to it (see _update_readout); 2D values are read straight from the sweep
## files, so the readout needs no textures.
##
## Upcoming loop frames (and their mosaic neighbours) are read in the background, see
## _preload_ahead() and VolumeCache.
##
## Mosaic mode also draws every other site's volume nearest in time (within
## Mosaic.MAX_SKEW_SEC), placed at its projected offset from the selected site and rotated
## for meridian convergence; the selected site draws on top.

const LIVE_RESCAN_SEC := 3.0
const LOOP_DWELL_SEC := 1.0  # extra pause on the last frame of the loop
## Automatic storm motion may come from a volume (any site) up to this far away in time.
const AUTO_STORM_MAX_SEC := 60 * 60
const VELOCITY_FIELDS := ["VEL", "DVEL"]
## Share of the cache budget that loop frames ahead of the playhead may fill.
const PRELOAD_BUDGET_FRACTION := 0.8
## Web: texture cache budget (the desktop's 1 GiB would not fit next to the in-memory volumes
## in a 32-bit wasm heap).
const WEB_CACHE_BUDGET_BYTES := 384 << 20
## Web: sweep bytes of decoded volumes held in memory (MemorySource evicts the oldest).
const WEB_MEMORY_BUDGET_BYTES := 900 << 20
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
const HINT_COMMON := (
	"Space play   Left/Right step   Shift+Left/Right prev/next loop   Home/End first/last\n"
	+ "[ ] speed   L live   Up/Down tilt   1-8 field   9 products   0 KDP/shear/HCA   S site\n"
	+ "M mosaic   V 2D/3D   R reset view   X section   F fetch   T storm-relative   W hodograph\n"
	+ "P VWP   A warnings   O SPC outlook   C cells   E export loop   "
)
const HINT_2D := "wheel zoom   drag pan   hover: value"
const HINT_SECTION := "wheel zoom   left drag: section A to B   right drag pan   hover: value"
const HINT_3D := (
	"left drag orbit   right drag pan   wheel zoom   B cones/volume   I isolate tilts   "
	+ ", . threshold   - = volume opacity   PgUp/PgDn height exaggeration"
)

var library := RadarLibrary.new()
var fetcher := Fetcher.new()
var overlays := Overlays.new()  # warnings and storm cells over the 2D view
var loop_export := LoopExport.new()
var cache := VolumeCache.new(library.source)
var site := ""
var frames: Array[String] = []  # volume names for `site`, ascending time
var frame := -1
var volume: RadarVolume
var sweep_index := -1  # sweep shown, resolved from field + target_elev
var field_name := "REF"
var target_elev := 0.5
var live := true
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
var _tracks: RotationTracks  # while the rotation tracks are on screen

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
	view_2d.section_changed.connect(_update_section)
	view_3d.camera.moved.connect(_update_info)
	add_child(fetcher)
	add_child(overlays)
	add_child(loop_export)
	overlays.changed.connect(_refresh_overlays)
	fetcher.job_updated.connect(_on_job_updated)
	fetcher.job_finished.connect(_on_job_finished)
	fetcher.volume_received.connect(_on_volume_received)
	_connect_hud()
	get_window().mouse_entered.connect(func() -> void: _mouse_in_window = true)
	get_window().mouse_exited.connect(func() -> void: _mouse_in_window = false)

	var opts := AppOptions.parse()
	if opts.has("volumes"):
		_set_source(DirSource.new(opts["volumes"]))
	elif fetcher.web:
		_set_source(MemorySource.new(WEB_MEMORY_BUDGET_BYTES), WEB_CACHE_BUDGET_BYTES)
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
	_apply_3d_options(opts)
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
	var sites := library.sites()
	var want_site: String = opts.get("site", "").to_upper()
	_select_site(want_site if sites.has(want_site) else library.site_of(library.latest()))
	if opts.has("time"):
		_go_to(RadarLibrary.nearest_in_time(frames, RadarLibrary.unix_of("X_" + opts["time"])))
		live = false
	_set_live(opts.get("live", "1" if live else "0") == "1")
	_set_playing(opts.get("play", "0") == "1")
	AppOptions.start_fetch(opts, fetcher)
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
			_set_live(false)
			_go_to(_sequence().x + i)
	)
	hud.speed_selected.connect(_set_fps)
	hud.live_toggled.connect(func() -> void: _set_live(not live))
	hud.site_selected.connect(_select_site)
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
			fetcher.start_update(s, at, from, to)
	)
	hud.fetch_panel.live_requested.connect(func(s: String) -> void: fetcher.start_live(s))
	hud.fetch_panel.stop_requested.connect(fetcher.stop_all)
	hud.fetch_panel.event_requested.connect(
		func(id: String) -> void: Events.start(Events.find(id), fetcher)
	)
	if not fetcher.can_live:
		hud.fetch_panel.disable_live("Live needs a cross-origin isolated page (COOP/COEP headers)")
	hud.srm_changed.connect(_adjust_storm)


func _apply_3d_options(opts: Dictionary) -> void:
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


## The project stretches canvas items with aspect "expand" from the 1280x800 design size, so
## the UI grows with big windows and the canvas fills any aspect ratio. Small windows would
## shrink the text too; instead the scale stays at least the screen's own (HiDPI) scale and
## the HUD reflows into the smaller canvas.
func _fit_ui_scale() -> void:
	var win := get_window()
	var design := Vector2(
		ProjectSettings.get_setting("display/window/size/viewport_width"),
		ProjectSettings.get_setting("display/window/size/viewport_height")
	)
	var stretch := minf(win.size.x / design.x, win.size.y / design.y)
	if stretch <= 0.0:
		return
	var screen_scale := DisplayServer.screen_get_scale(win.current_screen)
	win.content_scale_factor = maxf(stretch, screen_scale) * ui_scale / stretch


# --- state changes -------------------------------------------------------------------


func _select_site(s: String) -> void:
	var t := RadarLibrary.unix_of(frames[frame]) if frame >= 0 else 0
	site = s
	frames = library.for_site(site)
	hud.set_sites(library.sites(), site)
	# Keep roughly the same moment in time when switching sites.
	_go_to(RadarLibrary.nearest_in_time(frames, t) if t > 0 else frames.size() - 1)


func _go_to(i: int) -> void:
	if frames.is_empty():
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
	_set_playing(false)
	if delta < 0:
		_set_live(false)
	var seq := _sequence()
	_go_to(clampi(frame + delta, seq.x, seq.y))


## Jumps to the previous / next sequence: its last frame going back, its first going forward.
func _step_sequence(delta: int) -> void:
	var seq := _sequence()
	var i := seq.y + 1 if delta > 0 else seq.x - 1
	if i < 0 or i >= frames.size():
		return
	_set_playing(false)
	_set_live(false)
	_go_to(i)


func _set_view_3d(on: bool) -> void:
	view_is_3d = on
	view_2d.set_active(not on)
	view_3d.set_active(on)
	hud.set_view_3d(on)
	_update_hint()
	_refresh()


func _update_hint() -> void:
	var extra := HINT_3D if view_is_3d else (HINT_SECTION if section_on else HINT_2D)
	hud.set_hint(HINT_COMMON + extra)


func _set_section_on(on: bool) -> void:
	section_on = on
	view_2d.set_section_mode(on)
	_update_hint()
	_update_section()


func _toggle_mosaic() -> void:
	mosaic = not mosaic
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
	_set_playing(false)
	_set_live(false)
	_go_to(i)


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


## Rotation tracks of the current loop, rebuilt when the loop's volumes change.
func _update_tracks() -> RotationTracks:
	var vols := _loop_volumes()
	var names: Array[String] = []
	for v in vols:
		names.append(v.name)
	if _tracks == null or _tracks.names != names:
		_tracks = RotationTracks.build(vols)
	return _tracks


## Volumes of the loop around the current frame, oldest first.
func _loop_volumes() -> Array[RadarVolume]:
	var out: Array[RadarVolume] = []
	if frame < 0:
		return out
	var seq := _sequence()
	for k in range(seq.x, seq.y + 1):
		var v := cache.get_volume(frames[k])
		if v != null:
			out.append(v)
	return out


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


func _set_live(on: bool) -> void:
	live = on
	if on:
		live_timer.start()
		_on_live_tick()
	else:
		live_timer.stop()
	_update_playback()


func _set_playing(on: bool) -> void:
	playing = on
	if on:
		play_timer.start(1.0 / fps)
	else:
		play_timer.stop()
	_update_playback()


func _set_fps(v: float) -> void:
	fps = v
	_update_playback()


func _cycle_speed(delta: int) -> void:
	var i := Hud.SPEEDS.find(fps)
	if i < 0:
		i = Hud.DEFAULT_SPEED_INDEX
	_set_fps(Hud.SPEEDS[clampi(i + delta, 0, Hud.SPEEDS.size() - 1)])


func _sequence() -> Vector2i:
	return RadarLibrary.sequence_bounds(frames, maxi(frame, 0))


# --- fetching from the UI --------------------------------------------------------


func _toggle_fetch_panel() -> void:
	if hud.fetch_panel.visible:
		hud.fetch_panel.close_panel()
	else:
		var t := RadarLibrary.unix_of(volume.name) if volume != null else 0
		hud.fetch_panel.open_panel(site, t)


## New volumes from a running job show up in the library straight away. A live job for
## another site takes over the view once its first volume exists.
func _on_job_updated(job: Fetcher.Job) -> void:
	var lines := PackedStringArray()
	for j in fetcher.jobs:
		lines.append(j.describe())
	hud.fetch_panel.set_jobs(lines)
	if job.volumes.size() != job.get_meta("seen", 0):
		job.set_meta("seen", job.volumes.size())
		_rescan()
		if job.kind == "live" and job.volumes.size() == 1:
			_select_site(job.site)
			_set_live(true)
	_update_info()


func _on_volume_received(name: String, volume_json: String, files: Dictionary) -> void:
	var mem := library.source as MemorySource
	if mem != null:
		mem.add_volume(name, volume_json, files)


## A finished update jumps to the last volume it fetched (a notable event: to its peak).
func _on_job_finished(job: Fetcher.Job) -> void:
	print("fetch: ", job.describe())  # the web smoke test waits for this line
	if job.kind != "update" or job.stopped or job.volumes.is_empty():
		return
	_rescan()
	_set_live(false)
	_set_playing(false)
	if job.site != site:
		_select_site(job.site)
	var i := frames.find(job.volumes[-1])
	if job.has_meta("jump_to"):
		i = RadarLibrary.nearest_in_time(frames, job.get_meta("jump_to"))
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
	frames = library.for_site(site)
	if volume != null:
		frame = maxi(frames.find(volume.name), 0)
	_update_playback()


# --- timers --------------------------------------------------------------------------


func _on_live_tick() -> void:
	library.scan()
	var sites := library.sites()
	if site.is_empty() and not sites.is_empty():
		_select_site(library.site_of(library.latest()))
		return
	frames = library.for_site(site)
	if frames.is_empty():
		return
	if playing:
		_update_playback()  # new frames join the loop on the next pass
		return
	var newest := frames.size() - 1
	var same := volume != null and frames[newest] == volume.name
	if same and volume.is_complete():
		return
	_go_to(newest)  # new volume, or the current partial one grew


func _on_play_tick() -> void:
	var seq := _sequence()
	var next := frame + 1 if frame < seq.y else seq.x
	_go_to(next)
	var wait := 1.0 / fps
	if next == seq.y:
		wait += LOOP_DWELL_SEC
	if playing:
		play_timer.start(wait)


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
		_neighbors = Mosaic.neighbors(library, cache, volume, shown, target_elev)
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
		_tracks = null
	if view_is_3d:
		view_3d.show_volume(volume, _volume_field(), target_elev, _neighbors, _others)
	elif field_name == RotationTracks.VIEW_FIELD:
		view_2d.show_tracks(_update_tracks(), frame - _sequence().x + 1)
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
	overlays.update(view_2d, view_3d, volume, _loop_volumes(), frame - _sequence().x)
	_readout_key.clear()
	_update_info()


## VAD profiles of every volume in the current loop.
func _update_vwp() -> void:
	hud.set_vwp_shown(vwp_shown)
	if not vwp_shown:
		return
	var columns := []
	var seq := _sequence()
	if frame >= 0:
		for k in range(seq.x, seq.y + 1):
			var path := frames[k]
			var profile = library.winds(path).get("wind_profile")
			columns.append({"path": path, "t": RadarLibrary.unix_of(path), "profile": profile})
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
	var title := "VAD winds  %s %s  (m/s)" % [volume.icao(), _clock(volume.name)]
	var in_use := _storm_motion() if srm_on else Vector2.INF
	hud.hodograph.show_winds(own.get("wind_profile"), motion, in_use, title, _storm_source())


## "HH:MMZ" of a volume name.
static func _clock(path: String) -> String:
	var t := path.get_file().get_slice("_", 2)
	return "%s:%sZ" % [t.substr(0, 2), t.substr(2, 2)]


## Where the storm motion in effect comes from, for the info text and hodograph.
func _storm_source() -> String:
	var m := Hodograph.from_dir_speed(_storm_motion())
	var what := "storm from %03d° at %d m/s" % [roundi(m.x) % 360, roundi(m.y)]
	if not (srm_auto and not _auto_storm.is_empty()):
		return what + " (manual)"
	var src: String = _auto_storm["name"]
	if volume != null and src == volume.name:
		return what + " (Bunkers RM)"
	return what + " (Bunkers RM, %s %s)" % [RadarLibrary.site_of(src), _clock(src)]


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
			var other := Mosaic.path_near(library, nb["site"], t)
			if not other.is_empty():
				budget -= cache.prefetch(other, f, target_elev, need)


func _update_playback() -> void:
	var seq := _sequence()
	var t := ""
	if volume != null:
		t = volume.time_utc().replace("T", " ").left(19) + "Z"
	hud.set_playback(playing, live, frame - seq.x, seq.y - seq.x + 1, t, fps)


func _update_info() -> void:
	if volume == null:
		var help := "Run:  nexrad update KTLX   (or: nexrad live KTLX)"
		if fetcher.web:
			help = "Press F to fetch radar data"
		hud.set_info("No volumes in %s\n%s" % [library.source.describe(), help])
		return
	var lines := PackedStringArray()
	var partial := "" if volume.is_complete() else "  (partial)"
	var vcp := int(volume.meta.get("vcp", 0))
	lines.append(
		"%s  VCP %d%s   frame %d/%d" % [volume.icao(), vcp, partial, frame + 1, frames.size()]
	)
	if sweep_index >= 0:
		var sw := volume.sweep(sweep_index)
		var shown := _volume_field() if view_is_3d else field_name
		var tilts := volume.tilts(shown)
		var scanned := str(sw["time"]).substr(11, 8) + "Z"
		var elev := float(sw["elevation_deg"])
		var pos := tilts.find(sweep_index) + 1
		if volume.is_product(sweep_index):
			var what: String = Hud.PRODUCT_NAMES.get(field_name, "")
			var src := "AZSHR" if _sweep_field() == RotationTracks.FIELD else "REF"
			var n := volume.tilts(src).size()
			var from := "from %d %s tilts" % [n, src]
			if field_name == RotationTracks.VIEW_FIELD:
				var seq := _sequence()
				from = "over frames 1-%d of %d" % [frame - seq.x + 1, seq.y - seq.x + 1]
			lines.append("%s  %s %s  %s" % [field_name, what, from, scanned])
		else:
			lines.append(
				"tilt %d/%d  %.2f°  %s  scanned %s" % [pos, tilts.size(), elev, shown, scanned]
			)
	else:
		lines.append("%s not in this volume" % field_name)
	var cache_mb := cache.used_bytes() >> 20
	if view_is_3d:
		var thr := view_3d.threshold_of(field_name)
		var abs_mode := view_3d.threshold_is_abs(field_name)
		(
			lines
			. append(
				(
					"3D  %s   hide %s < %s %s   height x%.0f   cache %d MB"
					% [
						(
							"volume render, opacity %.3f/km" % view_3d.density
							if view_3d.volume_render
							else VolumeView3D.ISOLATE_NAMES[view_3d.isolate]
						),
						"|%s|" % field_name if abs_mode else field_name,
						str(snappedf(thr, 0.01)),
						Colormaps.unit_of(field_name).get_slice(" ", 0),
						view_3d.exaggeration,
						cache_mb,
					]
				)
			)
		)
	else:
		lines.append("zoom %.2f px/km   cache %d MB" % [view_2d.zoom(), cache_mb])
	if _storm_vector() != Vector2.ZERO:
		lines.append("storm-relative: " + _storm_source())
	var ml = volume.meta.get("melting_layer")
	if Colormaps.is_categorical(field_name) and ml is Dictionary:
		lines.append(
			(
				"melting layer %.1f-%.1f km ARL (%s)"
				% [ml["bottom_m"] / 1000.0, ml["top_m"] / 1000.0, ml["source"]]
			)
		)
	if mosaic:
		lines.append("mosaic: " + Mosaic.summary(_neighbors))
	lines.append_array(overlays.info_lines())
	for job in fetcher.running_jobs():
		lines.append("fetch: " + job.describe())
	hud.set_info("\n".join(lines))


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
			_set_live(false)
			_go_to(_sequence().x)
		KEY_END:
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
			_set_live(not live)
		KEY_S:
			_cycle_site()
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


func _cycle_site() -> void:
	var sites := library.sites()
	if sites.size() > 1:
		_select_site(sites[(sites.find(site) + 1) % sites.size()])
