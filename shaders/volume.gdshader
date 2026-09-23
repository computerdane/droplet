// Volume rendering of one radar volume by ray marching. The mesh is a unit box (2 x 1 x 2,
// centred) that the vertex shader stretches over the radar's cylinder of data: x, z in
// [-radius_km, radius_km], y from the ground to top_km * exaggeration. Back faces are drawn
// (cull_front) so it also works with the camera inside. Each fragment marches the view ray
// through the box front to back; every sample is turned into elevation angle and slant
// range with the 4/3 earth radius model (as section.gdshader), interpolated between the
// two tilts bracketing that elevation (or the nearest one within half a beamwidth), and
// composited with an opacity that grows with the value above the display threshold.
// Local frame as cone.gdshader: km, +x east, -z north, +y up (height x exaggeration).
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

#include "res://shaders/storm.gdshaderinc"

const int MAX_LAYERS = 24;
const float LUT_STEP_DEG = 0.25;
const int LUT_SIZE = 160;  // 0 .. 40 degrees
const float KE_A = 8494.67;  // 4/3 * 6371 km

uniform sampler2DArray tilts : filter_nearest, repeat_enable;
uniform sampler2D colormap : source_color, filter_linear, repeat_disable;
uniform int n_layers = 0;
uniform float elevs[MAX_LAYERS];
uniform vec3 geom[MAX_LAYERS];  // first gate centre (km), gate spacing (km), gates
// layer_lut[b] = highest layer with elevation <= b * LUT_STEP_DEG, or -1.
uniform int layer_lut[LUT_SIZE];
uniform float width = 1832.0;  // texture width in gates
uniform float radius_km = 460.0;
uniform float top_km = 20.0;
uniform float exaggeration = 4.0;
uniform float half_beam_deg = 0.475;
uniform float cmap_min = -30.0;
uniform float cmap_max = 80.0;
uniform float threshold = 15.0;
uniform bool threshold_abs = false;
uniform bool categorical = false;  // class codes (HCA): nearer tilt, no interpolation, even opacity
uniform float density = 0.05;  // opacity per km of ray at full strength
uniform int steps = 192;
uniform vec2 other_sites[16];  // mosaic, local frame +x east, +y south
uniform int n_other_sites = 0;

varying vec3 local_pos;

void vertex() {
	VERTEX = vec3(VERTEX.x * radius_km, (VERTEX.y + 0.5) * top_km * exaggeration, VERTEX.z * radius_km);
	local_pos = VERTEX;
}

float sample_layer(int k, float r, float u) {
	vec3 g = geom[k];
	float gate = (r - g.x) / g.y;
	if (gate < -0.5 || gate >= g.z - 0.5) {
		return -1000.0;
	}
	return texture(tilts, vec3((gate + 0.5) / width, u, float(k))).r;
}

// Value at a local point (radar-relative ground position and true height), or < -900.
float value_at(vec2 ground, float h) {
	float s = length(ground);
	for (int i = 0; i < n_other_sites; i++) {
		if (distance(ground, other_sites[i]) < s) {
			return -1000.0;
		}
	}
	float phi = s / KE_A;
	float x = (KE_A + h) * sin(phi);
	float half_phi = sin(0.5 * phi);
	float z = h * cos(phi) - 2.0 * KE_A * half_phi * half_phi;
	float elev = degrees(atan(z, x));
	float r = sqrt(x * x + z * z);
	float az = degrees(atan(ground.x, -ground.y));
	az = az < 0.0 ? az + 360.0 : az;
	float u = az / 360.0;

	if (elev < elevs[0]) {
		if (elevs[0] - elev > half_beam_deg) {
			return -1000.0;
		}
		return storm_relative(sample_layer(0, r, u), az, elevs[0]);
	}
	int k = layer_lut[clamp(int(elev / LUT_STEP_DEG), 0, LUT_SIZE - 1)];
	k = max(k, 0);
	if (k + 1 < n_layers && elevs[k + 1] <= elev) {
		k += 1;
	}
	if (k >= n_layers - 1) {
		if (elev - elevs[n_layers - 1] > half_beam_deg) {
			return -1000.0;
		}
		return storm_relative(sample_layer(n_layers - 1, r, u), az, elevs[n_layers - 1]);
	}
	float va = storm_relative(sample_layer(k, r, u), az, elevs[k]);
	float vb = storm_relative(sample_layer(k + 1, r, u), az, elevs[k + 1]);
	bool ok_a = va > -900.0;
	bool ok_b = vb > -900.0;
	if (ok_a && ok_b) {
		float w = (elev - elevs[k]) / (elevs[k + 1] - elevs[k]);
		return categorical ? (w < 0.5 ? va : vb) : mix(va, vb, w);
	}
	if (ok_a && elev - elevs[k] < half_beam_deg) {
		return va;
	}
	if (ok_b && elevs[k + 1] - elev < half_beam_deg) {
		return vb;
	}
	return -1000.0;
}

void fragment() {
	vec3 cam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vec3 dir = normalize(local_pos - cam);
	// Ray / box intersection (slabs).
	vec3 lo = vec3(-radius_km, 0.0, -radius_km);
	vec3 hi = vec3(radius_km, top_km * exaggeration, radius_km);
	vec3 inv = 1.0 / dir;
	vec3 t_lo = (lo - cam) * inv;
	vec3 t_hi = (hi - cam) * inv;
	vec3 t_min = min(t_lo, t_hi);
	vec3 t_max = max(t_lo, t_hi);
	float t0 = max(max(max(t_min.x, t_min.y), t_min.z), 0.0);
	float t1 = min(min(t_max.x, t_max.y), t_max.z);
	if (t1 <= t0 || n_layers == 0) {
		discard;
	}
	float dt = (t1 - t0) / float(steps);
	// Per-pixel jitter hides the banding of a fixed step count.
	float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
	float t = t0 + dt * jitter;
	float strength_span = max((threshold_abs ? max(abs(cmap_min), cmap_max) : cmap_max) - threshold, 1e-3);
	vec3 color = vec3(0.0);
	float alpha = 0.0;
	for (int i = 0; i < steps; i++) {
		vec3 p = cam + dir * t;
		float v = value_at(p.xz, p.y / exaggeration);
		if (v > -900.0) {
			float m = threshold_abs ? abs(v) : v;
			if (m >= threshold) {
				float w = categorical ? 0.5 : 0.15 + 0.85 * clamp((m - threshold) / strength_span, 0.0, 1.0);
				float a = 1.0 - exp(-density * w * dt);
				float c = clamp((v - cmap_min) / (cmap_max - cmap_min), 0.0, 1.0);
				color += (1.0 - alpha) * a * texture(colormap, vec2(c, 0.5)).rgb;
				alpha += (1.0 - alpha) * a;
				if (alpha > 0.97) {
					break;
				}
			}
		}
		t += dt;
	}
	if (alpha < 0.004) {
		discard;
	}
	ALBEDO = color / alpha;
	ALPHA = alpha;
}
