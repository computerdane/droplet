// Basemap lines on the 3D ground plane. VERTEX arrives as (lon, lat, 0); +y up, -z north.
// Lines fade out past fade_km so the flat plane does not run to the horizon.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never;
#include "res://shaders/basemap.gdshaderinc"

uniform vec4 color : source_color = vec4(1.0, 1.0, 1.0, 0.5);
uniform float height_km = 0.05;
uniform float fade_km = 480.0;

varying float dist_km;

void vertex() {
	vec2 p = project_lonlat(VERTEX.xy);
	dist_km = length(p);
	VERTEX = vec3(p.x, height_km, -p.y);
}

void fragment() {
	ALBEDO = color.rgb;
	ALPHA = color.a * (1.0 - smoothstep(fade_km * 0.85, fade_km, dist_km));
}
