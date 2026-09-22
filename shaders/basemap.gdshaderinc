// Azimuthal equidistant projection of lon/lat (degrees) around the radar site into local
// km (+x east, +y north). Distances and bearings from the site are exact, which matches
// how radar ground range is laid out. Shared by the 2D and 3D basemap shaders.
uniform vec2 site_lonlat = vec2(-97.27776, 35.33336);

const float EARTH_RADIUS_KM = 6371.0;

vec2 project_lonlat(vec2 lonlat) {
	float lat0 = radians(site_lonlat.y);
	float lat = radians(lonlat.y);
	float dlon = radians(lonlat.x - site_lonlat.x);
	// Angular distance via haversine: acos() of a cosine loses ~km near the site in float32.
	float sdlat = sin(0.5 * (lat - lat0));
	float sdlon = sin(0.5 * dlon);
	float hav = sdlat * sdlat + cos(lat0) * cos(lat) * sdlon * sdlon;
	float c = 2.0 * asin(sqrt(clamp(hav, 0.0, 1.0)));
	float k = c < 1e-6 ? 1.0 : c / sin(c);
	float x = k * cos(lat) * sin(dlon);
	float y = k * (cos(lat0) * sin(lat) - sin(lat0) * cos(lat) * cos(dlon));
	return vec2(x, y) * EARTH_RADIUS_KM;
}
