class_name InfoText
extends RefCounted
## The top-left info text: what main.gd shows of its state (site, scan, tilt, view, storm
## motion, mosaic, overlays, fetch jobs), built from main's fields and helpers.


## The text for `main` (main.gd) as it is now.
static func build(main: Node) -> String:
	if main.overview:
		var lines := PackedStringArray(["United States  ·  NOAA MRMS composite reflectivity"])
		lines.append("Select a radar marker to view its recent scans and follow live updates")
		lines.append_array(main.overlays.info_lines())
		return "\n".join(lines)
	if main.volume == null:
		return _no_volume(main)
	var lines := PackedStringArray()
	var volume: RadarVolume = main.volume
	var field_name: String = main.field_name
	var quality := VolumeUpdatePolicy.quality(volume)
	var vcp := int(volume.meta.get("vcp", 0))
	lines.append(
		(
			"%s  VCP %d%s   frame %d/%d"
			% [volume.icao(), vcp, quality, main.frame + 1, main.frames.size()]
		)
	)
	var sweep_index: int = main.sweep_index
	if sweep_index >= 0:
		var sw := volume.sweep(sweep_index)
		var shown: String = main._volume_field() if main.view_is_3d else field_name
		var tilts := volume.tilts(shown)
		var scanned := str(sw["time"]).substr(11, 8) + "Z"
		var elev := float(sw["elevation_deg"])
		var pos := tilts.find(sweep_index) + 1
		if volume.is_product(sweep_index):
			var what: String = Hud.PRODUCT_NAMES.get(field_name, "")
			var src := "AZSHR" if main._sweep_field() == RotationTracks.FIELD else "REF"
			var n := volume.tilts(src).size()
			var from := "from %d %s tilts" % [n, src]
			if field_name == RotationTracks.VIEW_FIELD:
				var seq: Vector2i = main._sequence()
				from = "over frames 1-%d of %d" % [main.frame - seq.x + 1, seq.y - seq.x + 1]
			lines.append("%s  %s %s  %s" % [field_name, what, from, scanned])
		else:
			lines.append(
				"tilt %d/%d  %.2f°  %s  scanned %s" % [pos, tilts.size(), elev, shown, scanned]
			)
	else:
		lines.append("%s not in this volume" % field_name)
	var cache_mb: int = main.cache.used_bytes() >> 20
	if main.view_is_3d:
		lines.append(_view_3d_line(main, cache_mb))
	else:
		lines.append("zoom %.2f px/km   cache %d MB" % [main.view_2d.zoom(), cache_mb])
	if main._storm_vector() != Vector2.ZERO:
		lines.append("storm-relative: " + main._storm_source())
	var ml = volume.meta.get("melting_layer")
	if Colormaps.is_categorical(field_name) and ml is Dictionary:
		lines.append(
			(
				"melting layer %.1f-%.1f km ARL (%s)"
				% [ml["bottom_m"] / 1000.0, ml["top_m"] / 1000.0, ml["source"]]
			)
		)
	if main.mosaic:
		lines.append("mosaic: " + Mosaic.summary(main._neighbors))
	lines.append_array(main.overlays.info_lines())
	for l in main.fetcher.status_lines():
		lines.append("fetch: " + l)
	return "\n".join(lines)


## Nothing on screen: the fetch jobs (running, or the last one if it failed), else how to get
## data.
static func _no_volume(main: Node) -> String:
	var fetcher: Fetcher = main.fetcher
	var jobs := fetcher.status_lines()
	if not jobs.is_empty():
		var state := (
			"waiting for first scan" if fetcher.running_jobs().size() > 0 else "fetch failed"
		)
		return "%s  %s\n%s" % [main.site, state, "\n".join(jobs)]
	var help := "Run:  nexrad update KTLX   (or: nexrad live KTLX)"
	if fetcher.web:
		help = "Press F to fetch radar data"
	var library: RadarLibrary = main.library
	if not library.for_site(main.site).is_empty():  # cached, but not in the window
		return "%s  no scans in this window\nPress F to fetch, L for live" % main.site
	return "No volumes in %s\n%s" % [library.source.describe(), help]


static func _view_3d_line(main: Node, cache_mb: int) -> String:
	var view_3d: VolumeView3D = main.view_3d
	var field_name: String = main.field_name
	var thr := view_3d.threshold_of(field_name)
	var abs_mode := view_3d.threshold_is_abs(field_name)
	return (
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
