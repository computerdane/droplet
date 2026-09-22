// Storm-relative velocity: subtracts the radial component of a storm motion from a radial
// velocity. storm_motion is in m/s, +x east, +y north, in the radar's local frame; zero
// (the default, and for fields other than velocity) leaves values unchanged. Sentinels
// (< -900: missing, range folded) pass through. Shared by ppi, cone and section shaders.
uniform vec2 storm_motion = vec2(0.0);

float storm_relative(float v, float az_deg, float elev_deg) {
	if (v < -900.0) {
		return v;
	}
	float az = radians(az_deg);
	return v - dot(storm_motion, vec2(sin(az), cos(az))) * cos(radians(elev_deg));
}
