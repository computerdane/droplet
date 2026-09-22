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
## live=0|1 play=0|1 fps=8 zoom=2 view=2d|3d yaw=30 pitch=25 dist=400 exag=4
## isolate=0|1|2 threshold=20

const LIVE_RESCAN_SEC := 3.0
const LOOP_DWELL_SEC := 1.0  # extra pause on the last frame of the loop
const FIELD_KEYS := {
	KEY_1: "REF", KEY_2: "VEL", KEY_3: "SW", KEY_4: "ZDR", KEY_5: "PHI", KEY_6: "RHO", KEY_7: "CFP"
}
const HINT_COMMON := (
	"Space play   Left/Right step   Home/End first/last   [ ] speed   L live   "
	+ "Up/Down tilt   1-7 field   S site   V 2D/3D   R reset view\n"
)
const HINT_2D := "wheel zoom   drag pan"
const HINT_3D := (
	"left drag orbit   right drag pan   wheel zoom   I isolate tilts   , . threshold   "
	+ "PgUp/PgDn height exaggeration"
)

var library := RadarLibrary.new()
var cache := VolumeCache.new()
var site := ""
var frames: Array[String] = []  # volume dirs for `site`, ascending time
var frame := -1
var volume: RadarVolume
var sweep_index := -1  # sweep shown, resolved from field + target_elev
var field_name := "REF"
var target_elev := 0.5
var live := true
var playing := false
var fps := 4.0
var view_is_3d := false

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
	view_3d.camera.moved.connect(_update_info)
	_connect_hud()

	var opts := _parse_options()
	field_name = opts.get("field", field_name).to_upper()
	target_elev = float(opts.get("elev", target_elev))
	fps = float(opts.get("fps", fps))
	if opts.has("zoom"):
		view_2d.set_zoom(float(opts["zoom"]))
	_apply_3d_options(opts)
	_set_view_3d(opts.get("view", "2d") == "3d")
	var sites := library.sites()
	var want_site: String = opts.get("site", "").to_upper()
	_select_site(want_site if sites.has(want_site) else library.site_of(library.latest()))
	if opts.has("time"):
		_go_to(RadarLibrary.nearest_in_time(frames, RadarLibrary.unix_of("X_" + opts["time"])))
		live = false
	_set_live(opts.get("live", "1" if live else "0") == "1")
	_set_playing(opts.get("play", "0") == "1")


func _connect_hud() -> void:
	hud.play_toggled.connect(func() -> void: _set_playing(not playing))
	hud.step_requested.connect(_step)
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


func _apply_3d_options(opts: Dictionary) -> void:
	var cam := view_3d.camera
	cam.set_view(
		float(opts.get("yaw", cam.yaw)),
		float(opts.get("pitch", cam.pitch)),
		float(opts.get("dist", cam.distance))
	)
	view_3d.set_exaggeration(float(opts.get("exag", view_3d.exaggeration)))
	view_3d.isolate = int(opts.get("isolate", view_3d.isolate)) as VolumeView3D.Isolate
	if opts.has("threshold"):
		view_3d.thresholds[field_name] = float(opts["threshold"])


func _parse_options() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if "=" in a:
			out[a.get_slice("=", 0)] = a.get_slice("=", 1)
	return out


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


func _step(delta: int) -> void:
	_set_playing(false)
	if delta < 0:
		_set_live(false)
	_go_to(frame + delta)


func _set_view_3d(on: bool) -> void:
	view_is_3d = on
	view_2d.set_active(not on)
	view_3d.set_active(on)
	hud.set_view_3d(on)
	hud.set_hint(HINT_COMMON + (HINT_3D if on else HINT_2D))
	_refresh()


func _set_field(f: String) -> void:
	field_name = f
	_refresh()


func _step_tilt(delta: int) -> void:
	if volume == null:
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
	var same := volume != null and frames[newest] == volume.path
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
	sweep_index = volume.tilt_near(field_name, target_elev) if volume != null else -1
	if view_is_3d:
		view_3d.show_volume(volume, field_name, sweep_index)
	else:
		view_2d.show_sweep(volume, sweep_index, field_name)
	var available: Array = []
	if volume != null:
		for i in volume.sweep_count():
			for f in volume.fields_of(i):
				if not available.has(f):
					available.append(f)
	hud.set_field(field_name, available)
	_update_info()
	_update_playback()


func _update_playback() -> void:
	var seq := _sequence()
	var t := ""
	if volume != null:
		t = volume.time_utc().replace("T", " ").left(19) + "Z"
	hud.set_playback(playing, live, frame - seq.x, seq.y - seq.x + 1, t, fps)


func _update_info() -> void:
	if volume == null:
		var help := "Run:  python -m nexrad update KTLX   (or: python -m nexrad live KTLX)"
		hud.set_info("No volumes in %s\n%s" % [library.root, help])
		return
	var lines := PackedStringArray()
	var partial := "" if volume.is_complete() else "  (partial)"
	var vcp := int(volume.meta.get("vcp", 0))
	lines.append(
		"%s  VCP %d%s   frame %d/%d" % [volume.icao(), vcp, partial, frame + 1, frames.size()]
	)
	if sweep_index >= 0:
		var sw := volume.sweep(sweep_index)
		var tilts := volume.tilts(field_name)
		var scanned := str(sw["time"]).substr(11, 8) + "Z"
		var elev := float(sw["elevation_deg"])
		var pos := tilts.find(sweep_index) + 1
		lines.append(
			"tilt %d/%d  %.2f°  %s  scanned %s" % [pos, tilts.size(), elev, field_name, scanned]
		)
	else:
		lines.append("%s not in this volume" % field_name)
	var cache_mb := cache.used_bytes() >> 20
	if view_is_3d:
		var thr := view_3d.threshold_of(field_name)
		var abs_mode: bool = VolumeView3D.DEFAULT_THRESHOLDS.get(field_name, [0, false])[1]
		(
			lines
			. append(
				(
					"3D  %s   hide %s < %s %s   height x%.0f   cache %d MB"
					% [
						VolumeView3D.ISOLATE_NAMES[view_3d.isolate],
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
	hud.set_info("\n".join(lines))


# --- input ---------------------------------------------------------------------------


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var e := event as InputEventKey
	match e.keycode:
		KEY_SPACE:
			_set_playing(not playing)
		KEY_LEFT:
			_step(-1)
		KEY_RIGHT:
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
		KEY_V:
			_set_view_3d(not view_is_3d)
		KEY_I:
			view_3d.isolate = (
				((view_3d.isolate + 1) % VolumeView3D.Isolate.size()) as VolumeView3D.Isolate
			)
			_refresh()
		KEY_COMMA:
			view_3d.adjust_threshold(field_name, -1)
			_refresh()
		KEY_PERIOD:
			view_3d.adjust_threshold(field_name, 1)
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


func _cycle_site() -> void:
	var sites := library.sites()
	if sites.size() > 1:
		_select_site(sites[(sites.find(site) + 1) % sites.size()])
