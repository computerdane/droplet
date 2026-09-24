class_name Mosaic
extends RefCounted
## Mosaic neighbours: other sites' volumes nearest in time to the one on screen, placed at
## their projected offset and rotated for meridian convergence (main.gd draws them).

const MAX_SKEW_SEC := 10 * 60
const MAX_KM := 900.0
## Sites live mode fetches along with the one on screen when the mosaic is on (nearest_sites).
const FETCH_NEIGHBORS := 4


## Volume of `s` nearest in time to `t` (inside `window`, when given), or "" if none is
## within MAX_SKEW_SEC.
static func path_near(
	library: RadarLibrary, s: String, t: int, window: TimeWindow = null
) -> String:
	var list := library.for_site(s, window)
	var i := RadarLibrary.nearest_in_time(list, t)
	if i < 0 or absi(RadarLibrary.unix_of(list[i]) - t) > MAX_SKEW_SEC:
		return ""
	return list[i]


## The `n` known sites (RadarSites) nearest `site` within MAX_KM, nearest first: the neighbours
## live mode fetches with it for the mosaic, few enough that clicking around does not fan out.
static func nearest_sites(site: String, n := FETCH_NEIGHBORS) -> Array[String]:
	var out: Array[String] = []
	var here := RadarSites.location(site)
	if here == Vector2.INF:
		return out
	var by_km := []
	for s in RadarSites.ids():
		var ll := RadarSites.location(s)
		var km := Basemap.project(ll.x, ll.y, here.x, here.y).length()
		if s != site and km <= MAX_KM:
			by_km.append([km, s])
	by_km.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	for e in by_km.slice(0, n):
		out.append(e[1])
	return out


## Other sites' volumes nearest in time to `volume` (inside `window`, when given), with the
## tilt of `field_name` nearest `elev` (loaded through `cache`), each with the positions of all
## the other radars in its own frame (`others`, see _assign_others):
## [{site, volume, sweep, offset_km (+y north), rotation (rad, clockwise), skew_sec, others}]
static func neighbors(
	library: RadarLibrary,
	cache: VolumeCache,
	volume: RadarVolume,
	field_name: String,
	elev: float,
	window: TimeWindow = null
) -> Array:
	var out := []
	var t := RadarLibrary.unix_of(volume.name)
	var lat0 := float(volume.meta["latitude"])
	var lon0 := float(volume.meta["longitude"])
	for s in library.sites():
		if s == volume.icao():
			continue
		var path := path_near(library, s, t, window)
		if path.is_empty():
			continue
		var skew := RadarLibrary.unix_of(path) - t
		var v := cache.get_volume(path, true)
		if v == null:
			continue
		var lat := float(v.meta["latitude"])
		var lon := float(v.meta["longitude"])
		var off := Basemap.project(lat, lon, lat0, lon0)
		if off.length() > MAX_KM:
			continue
		# The neighbour's north, as seen in the selected site's projection.
		var north := Basemap.project(lat + 0.05, lon, lat0, lon0) - off
		(
			out
			. append(
				{
					"site": s,
					"volume": v,
					"sweep": v.tilt_near(field_name, elev),
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
static func assign_others(neighbors: Array) -> PackedVector2Array:
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


## "KTSU -2:50, KFDR +1:05" for the info text.
static func summary(neighbors: Array) -> String:
	if neighbors.is_empty():
		return "no other site within %d min" % (MAX_SKEW_SEC / 60)
	var parts := PackedStringArray()
	for n in neighbors:
		var skew: int = n["skew_sec"]
		var sign := "-" if skew < 0 else "+"
		parts.append("%s %s%d:%02d" % [n["site"], sign, absi(skew) / 60, absi(skew) % 60])
	return ", ".join(parts)
