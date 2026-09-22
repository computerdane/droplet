// One elevation band of a vertical cross-section. The rect is the whole plot: UV.x runs
// along the section from A to B, UV.y from h_max_km (top) down to the ground. Each pixel is
// turned into an elevation angle and slant range with the 4/3 effective earth radius model
// (the inverse of cone.gdshader's beam) and drawn only if that angle is inside
// [lo_deg, hi_deg]; SectionView gives the bands so they tile without overlap.
// A band samples tilt "a", or with `blend` interpolates linearly in elevation between
// tilt a (below) and tilt b (above), falling back to whichever one has data if that tilt's
// beam (half a beamwidth) reaches the pixel.
// A and B are in the radar's local frame: km, +x east, +y south (as ppi.gdshader).
shader_type canvas_item;

uniform sampler2D sweep_a : filter_nearest, repeat_enable;
uniform sampler2D sweep_b : filter_nearest, repeat_enable;
uniform sampler2D colormap : filter_linear, repeat_disable;
uniform vec2 a_km;
uniform vec2 b_km;
uniform float h_max_km = 18.0;
uniform float lo_deg = 0.0;
uniform float hi_deg = 1.0;
uniform bool blend = false;
uniform float half_beam_deg = 0.475;
// Per tilt (a, b): elevation, first gate centre, gate spacing (km) and gate count.
uniform vec4 geom_a = vec4(0.5, 2.125, 0.25, 1192.0);
uniform vec4 geom_b = vec4(0.5, 2.125, 0.25, 1192.0);
uniform float cmap_min = -64.0;
uniform float cmap_max = 64.0;
uniform vec4 range_folded_color : source_color = vec4(0.55, 0.0, 0.55, 1.0);

const float KE_A = 8494.67;  // 4/3 * 6371 km

// Value of a tilt at slant range r (km) and azimuth fraction u; -1000 outside its gates.
float sample_tilt(sampler2D tex, vec4 geom, float r, float u) {
	float gate = (r - geom.y) / geom.z;
	if (gate < -0.5 || gate >= geom.w - 0.5) {
		return -1000.0;
	}
	return texture(tex, vec2((gate + 0.5) / geom.w, u)).r;
}

void fragment() {
	vec2 p = mix(a_km, b_km, UV.x);
	float h = (1.0 - UV.y) * h_max_km;
	float s = length(p);
	// Point at ground range s and height h, seen from the radar in the vertical plane:
	// x along the ground, z up. z = (a+h)cos(phi) - a without float32 cancellation.
	float phi = s / KE_A;
	float x = (KE_A + h) * sin(phi);
	float half_phi = sin(0.5 * phi);
	float z = h * cos(phi) - 2.0 * KE_A * half_phi * half_phi;
	float elev = degrees(atan(z, x));
	if (elev < lo_deg || elev >= hi_deg) {
		discard;
	}
	// Along the beam the slant range barely depends on elevation; use the pixel's own.
	float r = sqrt(x * x + z * z);
	float az = degrees(atan(p.x, -p.y));
	float u = (az < 0.0 ? az + 360.0 : az) / 360.0;

	float va = sample_tilt(sweep_a, geom_a, r, u);
	float v = va;
	if (blend) {
		float vb = sample_tilt(sweep_b, geom_b, r, u);
		bool ok_a = va > -900.0;
		bool ok_b = vb > -900.0;
		float t = (elev - geom_a.x) / (geom_b.x - geom_a.x);
		if (ok_a && ok_b) {
			v = mix(va, vb, t);
		} else if (ok_a && elev - geom_a.x < half_beam_deg) {
			v = va;
		} else if (ok_b && geom_b.x - elev < half_beam_deg) {
			v = vb;
		} else {
			// Nothing valid in reach: show range folding of the nearer tilt, if any.
			v = t < 0.5 ? va : vb;
			if (v > -1500.0) {
				discard;
			}
		}
	}
	if (v < -1500.0) {
		COLOR = range_folded_color;
	} else if (v < -900.0) {
		discard;
	} else {
		float c = clamp((v - cmap_min) / (cmap_max - cmap_min), 0.0, 1.0);
		COLOR = texture(colormap, vec2(c, 0.5));
	}
}
