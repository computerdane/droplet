// Basemap lines in the 2D plan view. VERTEX arrives as (lon, lat); screen y points south.
shader_type canvas_item;
#include "res://shaders/basemap.gdshaderinc"

void vertex() {
	vec2 p = project_lonlat(VERTEX);
	VERTEX = vec2(p.x, -p.y);
}
