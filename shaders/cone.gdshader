// One elevation sweep as a cone in 3D. The mesh is a unit grid: UV.x runs from the inner
// edge of gate 0 to the outer edge of the last gate, UV.y is azimuth (0..1 = 0..360°
// clockwise from north). The vertex shader bends it along the radar beam using the 4/3
// effective earth radius model, so the fragment shader samples the sweep texture at UV
// directly. World units are km: +x east, -z north, +y up (height scaled by exaggeration).
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D sweep : filter_nearest, repeat_enable;
uniform sampler2D colormap : source_color, filter_linear, repeat_disable;
uniform float elevation_deg = 0.5;
uniform float first_gate_km = 2.125;
uniform float gate_spacing_km = 0.25;
uniform int n_gates = 1832;
uniform float cmap_min = -30.0;
uniform float cmap_max = 80.0;
uniform float exaggeration = 4.0;
// Values below threshold are not drawn (|value| when threshold_abs, e.g. for velocity).
uniform float threshold = -10000.0;
uniform bool threshold_abs = false;
uniform bool show_range_folded = false;
uniform vec4 range_folded_color : source_color = vec4(0.55, 0.0, 0.55, 1.0);

const float KE_A = 8494.67;  // 4/3 * 6371 km

void vertex() {
	float r = max(first_gate_km - 0.5 * gate_spacing_km + UV.x * float(n_gates) * gate_spacing_km, 0.0);
	float th = radians(elevation_deg);
	// h = sqrt(r² + ke_a² + 2 r ke_a sinθ) - ke_a, rearranged to avoid float32 cancellation.
	float num = r * r + 2.0 * r * KE_A * sin(th);
	float h = num / (sqrt(num + KE_A * KE_A) + KE_A);
	float s = KE_A * asin(r * cos(th) / (KE_A + h));  // ground range
	float az = UV.y * TAU;
	VERTEX = vec3(s * sin(az), h * exaggeration, -s * cos(az));
}

void fragment() {
	float v = texture(sweep, UV).r;
	if (v < -1500.0) {
		if (!show_range_folded) {
			discard;
		}
		ALBEDO = range_folded_color.rgb;
	} else if (v < -900.0 || (threshold_abs ? abs(v) : v) < threshold) {
		discard;
	} else {
		float t = clamp((v - cmap_min) / (cmap_max - cmap_min), 0.0, 1.0);
		ALBEDO = texture(colormap, vec2(t, 0.5)).rgb;
	}
}
