class_name Readout
extends RefCounted
## Hover readout text for the 2D view (main._update_readout decides which panel is hovered).


## Readout at a 2D view point `p` (km, +x east, +y south of the selected radar), from the
## radar that draws that pixel: the nearest one, as in the mosaic shaders. `ctx` holds what is
## on screen: volume, sweep, field, neighbors (Mosaic.neighbors), storm (m/s in the selected
## site's frame, zero = ground-relative), site_lonlat, tracks (loop volumes while the rotation
## tracks are shown, else empty) with n_tracks frames, overlays (warnings and cells).
static func plan_view(p: Vector2, ctx: Dictionary) -> String:
	var vol: RadarVolume = ctx["volume"]
	var i: int = ctx["sweep"]
	var field_name: String = ctx["field"]
	var base_storm: Vector2 = ctx["storm"]
	var storm := base_storm
	var tracks: Array[RadarVolume] = ctx["tracks"]
	var local := p
	for n in [] if not tracks.is_empty() else ctx["neighbors"]:  # tracks: selected site only
		var off: Vector2 = n["offset_km"]
		var q := (p - Vector2(off.x, -off.y)).rotated(-float(n["rotation"]))
		if q.length() < local.length():
			vol = n["volume"]
			i = n["sweep"]
			local = q
			storm = base_storm.rotated(n["rotation"])
	var r := local.length()
	var az := fposmod(rad_to_deg(atan2(local.x, -local.y)), 360.0)
	var lines := PackedStringArray()
	if i >= 0:
		var elev := vol.elevation(i)
		var v := vol.value_at(i, field_name, az, r)
		if not tracks.is_empty():
			v = RotationTracks.value_at(tracks, ctx["n_tracks"], az, r)
		v = RadarVolume.storm_relative(v, storm, az, elev)
		var srm := "  storm-rel." if storm != Vector2.ZERO and v > -900.0 else ""
		lines.append("%s  %s%s" % [field_name, Colormaps.format_value(field_name, v), srm])
		var th := deg_to_rad(elev)
		var ka := SectionView.KE_A
		var h := sqrt(r * r + ka * ka + 2.0 * r * ka * sin(th)) - ka
		var where := "%s  %.1f km @ %03d°" % [vol.icao(), r, roundi(az) % 360]
		if vol.is_product(i):
			lines.append("%s   column of %d tilts" % [where, vol.tilts("REF").size()])
		else:
			lines.append("%s   %.2f° beam %.2f km ARL" % [where, elev, h])
	else:
		lines.append("%s: no %s" % [vol.icao(), field_name])
		lines.append("%s  %.1f km @ %03d°" % [vol.icao(), r, roundi(az) % 360])
	var site_ll: Vector2 = ctx["site_lonlat"]
	var ll := Basemap.unproject(Vector2(p.x, -p.y), site_ll.y, site_ll.x)
	lines.append(
		(
			"%.3f°%s  %.3f°%s"
			% [absf(ll.x), "N" if ll.x >= 0 else "S", absf(ll.y), "E" if ll.y >= 0 else "W"]
		)
	)
	var overlays: Overlays = ctx["overlays"]
	lines.append_array(overlays.readout_lines(Vector2(ll.y, ll.x), Vector2(p.x, -p.y)))
	return "\n".join(lines)
