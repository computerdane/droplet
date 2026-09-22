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
## pitch=25 dist=400 exag=4 isolate=0|1|2 threshold=20 mosaic=0|1 prefetch=0|1
## section=ax,ay,bx,by (cross-section A -> B, km east,north of the radar)
## srm=240,10 (storm-relative velocity, storm moving from 240 degrees at 10 m/s)
##
## Upcoming loop frames (and their mosaic neighbours) are read in the background, see
## _preload_ahead() and VolumeCache.
##
## Mosaic mode also draws every other site's volume nearest in time (within
## MOSAIC_MAX_SKEW_SEC), placed at its projected offset from the selected site and rotated
## for meridian convergence; the selected site draws on top.

const LIVE_RESCAN_SEC := 3.0
const LOOP_DWELL_SEC := 1.0  # extra pause on the last frame of the loop
const MOSAIC_MAX_SKEW_SEC := 10 * 60
const MOSAIC_MAX_KM := 900.0
const VELOCITY_FIELDS := ["VEL", "DVEL"]
## Share of the cache budget that loop frames ahead of the playhead may fill.
const PRELOAD_BUDGET_FRACTION := 0.8
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
	"Space play   Left/Right step   Home/End first/last   [ ] speed   L live   Up/Down tilt\n"
	+ "1-8 field   S site   M mosaic   V 2D/3D   R reset view   X section   T storm-relative\n"
)
const HINT_2D := "wheel zoom   drag pan"
const HINT_SECTION := "wheel zoom   left drag: section A to B   right drag pan"
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
var mosaic := false
var prefetch := true  # read upcoming loop frames in the background
var section_on := false  # cross-section mode: line in the 2D view, panel in the HUD
var srm_on := false  # storm-relative velocity
var storm_from_deg := 240.0  # meteorological: direction the storm moves from
var storm_speed := 10.0  # m/s
var _neighbors: Array = []  # mosaic entries, see _find_neighbors()
var _others := PackedVector2Array()  # neighbours in the selected site's frame
var _site_lonlat := Vector2.INF  # site the views' basemaps are centred on

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
	_connect_hud()

	var opts := _parse_options()
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
	if opts.has("srm"):
		var m: PackedFloat64Array = opts["srm"].split_floats(",")
		if m.size() == 2:
			storm_from_deg = m[0]
			storm_speed = m[1]
			srm_on = true
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


func _process(_delta: float) -> void:
	cache.poll()


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
	hud.mosaic_toggled.connect(_toggle_mosaic)
	hud.section_toggled.connect(func() -> void: _set_section_on(not section_on))
	hud.srm_toggled.connect(_toggle_srm)
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


func _adjust_storm(d_from_deg: float, d_speed: float) -> void:
	storm_from_deg = fposmod(storm_from_deg + d_from_deg, 360.0)
	storm_speed = clampf(storm_speed + d_speed, 0.0, 60.0)
	srm_on = true
	_refresh()


## Storm motion (m/s, +x east, +y north) to subtract, or zero when storm-relative display
## is off or the field is not a velocity.
func _storm_vector() -> Vector2:
	if not (srm_on and VELOCITY_FIELDS.has(field_name)):
		return Vector2.ZERO
	var heading := deg_to_rad(storm_from_deg + 180.0)  # direction it moves towards
	return Vector2(sin(heading), cos(heading)) * storm_speed


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
	if volume != null:
		var ll := Vector2(float(volume.meta["longitude"]), float(volume.meta["latitude"]))
		if ll != _site_lonlat:
			_site_lonlat = ll
			view_2d.set_site(ll.y, ll.x)
			view_3d.set_site(ll.y, ll.x)
	_neighbors = _find_neighbors()
	_others = _assign_others(_neighbors)
	var on_screen: Array = [volume.path] if volume != null else []
	for n in _neighbors:
		on_screen.append((n["volume"] as RadarVolume).path)
	cache.pin(on_screen)
	var storm := _storm_vector()
	view_2d.storm_motion = storm
	view_3d.storm_motion = storm
	hud.section.storm_motion = storm
	if view_is_3d:
		view_3d.show_volume(volume, field_name, target_elev, _neighbors, _others)
	else:
		view_2d.show_sweep(volume, sweep_index, field_name, _neighbors, _others)
	hud.set_mosaic(mosaic, library.sites().size() > 1)
	var available: Array = []
	if volume != null:
		for i in volume.sweep_count():
			for f in volume.fields_of(i):
				if not available.has(f):
					available.append(f)
	hud.set_field(field_name, available, storm != Vector2.ZERO)
	hud.set_srm(VELOCITY_FIELDS.has(field_name), srm_on, storm_from_deg, storm_speed)
	_update_section()
	_update_info()
	_update_playback()
	_preload_ahead()


func _update_section() -> void:
	var shown := section_on and view_2d.has_section
	hud.set_section(section_on, shown)
	if shown:
		hud.section.show_section(volume, field_name, view_2d.section_a, view_2d.section_b)


## Queues background reads of the frames after the current one, wrapping around the loop,
## with the textures the active view needs, until PRELOAD_BUDGET_FRACTION of the cache
## would be used. Mosaic neighbours of each frame are included.
func _preload_ahead() -> void:
	if volume == null or not prefetch:
		return
	var seq := _sequence()
	var n := seq.y - seq.x + 1
	var budget := int(cache.budget_bytes * PRELOAD_BUDGET_FRACTION)
	budget -= cache.prefetch(volume.path, field_name, target_elev, view_is_3d)
	for nb in _neighbors:
		budget -= cache.prefetch(nb["volume"].path, field_name, target_elev, view_is_3d)
	for k in range(1, n):
		if budget <= 0:
			break
		var path := frames[seq.x + (frame - seq.x + k) % n]
		budget -= cache.prefetch(path, field_name, target_elev, view_is_3d)
		var t := RadarLibrary.unix_of(path)
		for nb in _neighbors:
			var other := _mosaic_path(nb["site"], t)
			if not other.is_empty():
				budget -= cache.prefetch(other, field_name, target_elev, view_is_3d)


## Volume of `s` nearest in time to `t`, or "" if none is within MOSAIC_MAX_SKEW_SEC.
func _mosaic_path(s: String, t: int) -> String:
	var list := library.for_site(s)
	var i := RadarLibrary.nearest_in_time(list, t)
	if i < 0 or absi(RadarLibrary.unix_of(list[i]) - t) > MOSAIC_MAX_SKEW_SEC:
		return ""
	return list[i]


## Other sites' volumes nearest in time to the current one, for mosaic mode:
## [{site, volume, sweep, offset_km (+y north), rotation (rad, clockwise), skew_sec}]
func _find_neighbors() -> Array:
	var out := []
	if not mosaic or volume == null:
		return out
	var t := RadarLibrary.unix_of(volume.path)
	var lat0 := float(volume.meta["latitude"])
	var lon0 := float(volume.meta["longitude"])
	for s in library.sites():
		if s == site:
			continue
		var path := _mosaic_path(s, t)
		if path.is_empty():
			continue
		var skew := RadarLibrary.unix_of(path) - t
		var v := cache.get_volume(path, true)
		if v == null:
			continue
		var lat := float(v.meta["latitude"])
		var lon := float(v.meta["longitude"])
		var off := Basemap.project(lat, lon, lat0, lon0)
		if off.length() > MOSAIC_MAX_KM:
			continue
		# The neighbour's north, as seen in the selected site's projection.
		var north := Basemap.project(lat + 0.05, lon, lat0, lon0) - off
		(
			out
			. append(
				{
					"site": s,
					"volume": v,
					"sweep": v.tilt_near(field_name, target_elev),
					"offset_km": off,
					"rotation": atan2(north.x, north.y),
					"skew_sec": skew,
				}
			)
		)
	return out


## For nearest-radar compositing, give each neighbour the positions of all the other
## radars in its own local frame (+x east, +y south, as both shaders use). Returns the
## neighbours' positions in the selected site's frame.
static func _assign_others(neighbors: Array) -> PackedVector2Array:
	var pos := PackedVector2Array([Vector2.ZERO])  # selected site first
	var rot := PackedFloat32Array([0.0])
	for n in neighbors:
		var off: Vector2 = n["offset_km"]
		pos.append(Vector2(off.x, -off.y))
		rot.append(n["rotation"])
	for k in neighbors.size():
		var others := PackedVector2Array()
		for j in pos.size():
			if j != k + 1:
				others.append((pos[j] - pos[k + 1]).rotated(-rot[k + 1]))
		neighbors[k]["others"] = others
	return pos.slice(1)


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
		var abs_mode := view_3d.threshold_is_abs(field_name)
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
	if _storm_vector() != Vector2.ZERO:
		lines.append(
			"storm-relative: storm from %03d° at %d m/s" % [int(storm_from_deg), int(storm_speed)]
		)
	if mosaic:
		lines.append("mosaic: " + _mosaic_summary())
	hud.set_info("\n".join(lines))


func _mosaic_summary() -> String:
	if _neighbors.is_empty():
		return "no other site within %d min" % (MOSAIC_MAX_SKEW_SEC / 60)
	var parts := PackedStringArray()
	for n in _neighbors:
		var skew: int = n["skew_sec"]
		var sign := "-" if skew < 0 else "+"
		parts.append("%s %s%d:%02d" % [n["site"], sign, absi(skew) / 60, absi(skew) % 60])
	return ", ".join(parts)


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
		KEY_M:
			_toggle_mosaic()
		KEY_V:
			_set_view_3d(not view_is_3d)
		KEY_X:
			_set_section_on(not section_on)
		KEY_T:
			_toggle_srm()
		KEY_I:
			view_3d.isolate = ((view_3d.isolate + 1) % ConeSet.Isolate.size()) as ConeSet.Isolate
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
