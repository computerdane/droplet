extends "res://tests/test_case.gd"
## Map projection, basemap loading and the beam model the section shares with the cones.

const RadarVolumeScript := preload("res://scripts/radar_volume.gd")
const BasemapScript := preload("res://scripts/basemap.gd")
const SectionViewScript := preload("res://scripts/section_view.gd")


## 1 degree of latitude due north is about 111.19 km; unproject inverts project.
func test_projection() -> void:
	var vol = RadarVolumeScript.load_from_dir(lib.volumes[0])
	var lat: float = vol.meta["latitude"]
	var lon: float = vol.meta["longitude"]
	var p: Vector2 = BasemapScript.project(lat + 1.0, lon, lat, lon)
	check(absf(p.x) < 1e-6 and absf(p.y - 111.195) < 0.01, "1 deg north -> %s" % p)
	var worst := 0.0
	for q in [Vector2(120, -45), Vector2(-300, 210), Vector2(0.5, 0.2), Vector2(-450, -450)]:
		var ll: Vector2 = BasemapScript.unproject(q, lat, lon)
		worst = maxf(worst, BasemapScript.project(ll.x, ll.y, lat, lon).distance_to(q))
	check(worst < 0.01, "unproject round trip off by %.5f km" % worst)


func test_basemap() -> void:
	var bm = BasemapScript.get_shared()
	if bm == null:
		note("not built (python -m nexrad basemap)")
		return
	check(not bm.meshes.is_empty(), "basemap has layers")
	note("layers: %s" % [bm.meshes.keys()])


## The cross-section's beam height at a ground range must match cone.gdshader's forward model
## (slant range -> height, ground range), replicated here.
func test_beam_model() -> void:
	var ke_a := 8494.67
	var worst := 0.0
	for elev in [0.5, 3.0, 19.5]:
		for r in [10.0, 100.0, 300.0]:
			var th := deg_to_rad(elev)
			var num: float = r * r + 2.0 * r * ke_a * sin(th)
			var h: float = num / (sqrt(num + ke_a * ke_a) + ke_a)
			var s: float = ke_a * asin(r * cos(th) / (ke_a + h))
			worst = maxf(worst, absf(SectionViewScript.beam_height(elev, s) - h))
	check(worst <= 0.01, "section beam height off cone.gdshader by %.4f km" % worst)
