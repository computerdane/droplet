// Rotation tracks: the largest low-level rotation (ROT, one layer per loop frame) over the
// first n_layers frames, drawn like ppi.gdshader draws a sweep. Layers share one ground-range
// geometry (RotationTracks pads narrower ones with MISSING).
shader_type canvas_item;

uniform sampler2DArray layers : filter_nearest, repeat_enable;  // R = value, width gates
uniform sampler2D colormap : filter_linear, repeat_disable;
uniform int n_layers = 0;
uniform float half_size = 500.0;  // km
uniform float first_gate_km = 2.125;
uniform float gate_spacing_km = 0.25;
uniform int n_gates = 1832;
uniform float cmap_min = -10.0;
uniform float cmap_max = 20.0;
uniform float min_value = 0.0;  // weaker (and anticyclonic) rotation is left out

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 * half_size;
	float r = length(p);
	float az = degrees(atan(p.x, -p.y));
	if (az < 0.0) {
		az += 360.0;
	}
	float gate = (r - first_gate_km) / gate_spacing_km;
	if (gate < -0.5 || gate >= float(n_gates) - 0.5) {
		discard;
	}
	vec2 uv = vec2((gate + 0.5) / float(n_gates), az / 360.0);
	float v = -1000.0;
	for (int k = 0; k < n_layers; k++) {
		v = max(v, texture(layers, vec3(uv, float(k))).r);
	}
	if (v < min_value) {
		discard;
	}
	float t = clamp((v - cmap_min) / (cmap_max - cmap_min), 0.0, 1.0);
	COLOR = texture(colormap, vec2(t, 0.5));
}
