// Plan Position Indicator: draws one polar sweep onto a flat quad centred on the radar.
// World units are kilometres; the quad spans [-half_size, half_size] on both axes,
// +x east, -y north (screen y points down).
shader_type canvas_item;

#include "res://shaders/storm.gdshaderinc"

uniform sampler2D sweep : filter_nearest, repeat_enable;   // R = value, width gates, height az bins
uniform sampler2D colormap : filter_linear, repeat_disable;
uniform float half_size = 500.0;      // km
uniform float first_gate_km = 2.125;  // range to centre of gate 0
uniform float gate_spacing_km = 0.25;
uniform int n_gates = 1832;
uniform float elevation_deg = 0.5;  // for storm-relative velocity
uniform float cmap_min = -30.0;
uniform float cmap_max = 80.0;
uniform float missing_below = -900.0; // sentinel threshold: MISSING = -1000, RANGE_FOLDED = -2000
uniform vec4 range_folded_color : source_color = vec4(0.55, 0.0, 0.55, 1.0);
uniform bool show_range_folded = true;
// Mosaic: other radars in this quad's local frame (km, +x east, +y south). A pixel closer
// to one of them belongs to that radar (nearest-radar compositing, lowest beam wins).
uniform vec2 other_sites[16];
uniform int n_other_sites = 0;

void fragment() {
	vec2 p = (UV - 0.5) * 2.0 * half_size;
	float r = length(p);
	for (int i = 0; i < n_other_sites; i++) {
		if (distance(p, other_sites[i]) < r) {
			discard;
		}
	}
	float az = degrees(atan(p.x, -p.y));
	if (az < 0.0) {
		az += 360.0;
	}
	float gate = (r - first_gate_km) / gate_spacing_km;
	if (gate < -0.5 || gate >= float(n_gates) - 0.5) {
		discard;
	}
	vec2 uv = vec2((gate + 0.5) / float(n_gates), az / 360.0);
	float v = storm_relative(texture(sweep, uv).r, az, elevation_deg);
	if (v < -1500.0) {
		if (show_range_folded) {
			COLOR = range_folded_color;
		} else {
			discard;
		}
	} else if (v < missing_below) {
		discard;
	} else {
		float t = clamp((v - cmap_min) / (cmap_max - cmap_min), 0.0, 1.0);
		COLOR = texture(colormap, vec2(t, 0.5));
	}
}
