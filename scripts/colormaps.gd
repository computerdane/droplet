class_name Colormaps
extends RefCounted
## Colour ramps per radar moment, as 1D gradient textures plus the value range they span.

## [min, max] of each field in physical units.
const RANGES := {
	"REF": [-30.0, 80.0],  # dBZ
	"VEL": [-64.0, 64.0],  # m/s, negative = toward radar
	"SW": [0.0, 20.0],  # m/s
	"ZDR": [-4.0, 8.0],  # dB
	"PHI": [0.0, 360.0],  # degrees
	"RHO": [0.2, 1.05],  # unitless
	"CFP": [0.0, 60.0],  # dB
	"DVEL": [-64.0, 64.0],  # m/s, dealiased VEL
	"KDP": [-1.0, 7.0],  # deg/km, specific differential phase
	"AZSHR": [-10.0, 20.0],  # 1e-3 /s, azimuthal shear of DVEL (+ cyclonic)
	"CREF": [-30.0, 80.0],  # dBZ, composite (column maximum)
	"ET": [0.0, 20.0],  # km above the radar, 18 dBZ echo top
	"VIL": [0.0, 80.0],  # kg/m², vertically integrated liquid
}

const UNITS := {
	"REF": "dBZ",
	"VEL": "m/s (- toward)",
	"SW": "m/s",
	"ZDR": "dB",
	"PHI": "deg",
	"RHO": "CC",
	"CFP": "dB",
	"DVEL": "m/s (- toward)",
	"KDP": "°/km",
	"AZSHR": "10⁻³/s",
	"CREF": "dBZ",
	"ET": "km ARL",
	"VIL": "kg/m²",
}

## Stops as [value, colour] pairs.
const STOPS := {
	"REF":
	[
		[-30.0, "1a1a2e"],
		[0.0, "2b2b55"],
		[5.0, "04e9e6"],
		[10.0, "019ff4"],
		[15.0, "0300f4"],
		[20.0, "02fd02"],
		[25.0, "01c501"],
		[30.0, "008e00"],
		[35.0, "fdf802"],
		[40.0, "e5bc00"],
		[45.0, "fd9500"],
		[50.0, "fd0000"],
		[55.0, "d40000"],
		[60.0, "bc0000"],
		[65.0, "f800fd"],
		[70.0, "9854c6"],
		[75.0, "fdfdfd"],
		[80.0, "ffffff"],
	],
	"VEL":
	[
		[-64.0, "00ffff"],
		[-40.0, "00e000"],
		[-10.0, "005000"],
		[0.0, "707070"],
		[10.0, "500000"],
		[40.0, "e00000"],
		[64.0, "ff00ff"],
	],
	"SW": [[0.0, "101010"], [5.0, "2050c0"], [10.0, "f0f000"], [15.0, "f00000"], [20.0, "c000f0"]],
	"ZDR":
	[
		[-4.0, "404040"],
		[0.0, "2050c0"],
		[1.0, "00c080"],
		[2.5, "f0f000"],
		[4.0, "f06000"],
		[6.0, "f00000"],
		[8.0, "f000f0"],
	],
	"PHI":
	[[0.0, "202060"], [90.0, "00c0c0"], [180.0, "f0f000"], [270.0, "f00000"], [360.0, "202060"]],
	"RHO":
	[
		[0.2, "202020"],
		[0.7, "2050c0"],
		[0.9, "00c000"],
		[0.97, "f0f000"],
		[1.0, "f00000"],
		[1.05, "ffffff"],
	],
	"CFP": [[0.0, "101010"], [20.0, "2050c0"], [40.0, "f0f000"], [60.0, "f00000"]],
	"KDP":
	[
		[-1.0, "404040"],
		[0.0, "202060"],
		[0.5, "2050c0"],
		[1.0, "00c0c0"],
		[2.0, "00c000"],
		[3.0, "f0f000"],
		[4.5, "f08000"],
		[6.0, "f00000"],
		[7.0, "f000f0"],
	],
	"AZSHR":
	[
		[-10.0, "00c0f0"],
		[-4.0, "004060"],
		[0.0, "202020"],
		[2.0, "404040"],
		[4.0, "808000"],
		[7.0, "f0f000"],
		[10.0, "f08000"],
		[14.0, "f00000"],
		[20.0, "ff60ff"],
	],
	"ET":
	[
		[0.0, "202040"],
		[2.0, "2050c0"],
		[5.0, "00c0c0"],
		[8.0, "00c000"],
		[11.0, "f0f000"],
		[14.0, "f08000"],
		[17.0, "f00000"],
		[20.0, "f000f0"],
	],
	"VIL":
	[
		[0.0, "202040"],
		[5.0, "2050c0"],
		[10.0, "00c000"],
		[20.0, "f0f000"],
		[35.0, "f08000"],
		[50.0, "f00000"],
		[65.0, "f000f0"],
		[80.0, "ffffff"],
	],
}

## Fields drawn with another field's colours.
const SAME_AS := {"DVEL": "VEL", "CREF": "REF"}

const KT_PER_MS := 1.94384

static var _cache: Dictionary = {}


static func range_of(field_name: String) -> Array:
	return RANGES.get(field_name, [0.0, 1.0])


static func unit_of(field_name: String) -> String:
	return UNITS.get(field_name, "")


## A value for display with its unit ("-23.5 m/s (-46 kt)"), or what a sentinel means.
static func format_value(field_name: String, v: float) -> String:
	if v < -1500.0:
		return "range folded"
	if v < -900.0:
		return "no data"
	var unit := unit_of(field_name).get_slice(" ", 0)
	match field_name:
		"RHO":
			return "%.3f" % v
		"PHI":
			return "%.0f°" % v
		"VEL", "DVEL", "SW":
			return "%.1f %s (%.0f kt)" % [v, unit, v * KT_PER_MS]
		"ET":
			return "%.1f km ARL (%.0f kft)" % [v, v * 3.28084]
		"KDP":
			return "%.2f °/km" % v
		"AZSHR":
			return "%.1f × 10⁻³/s" % v
	return "%.1f %s" % [v, unit]


static func texture_for(field_name: String) -> GradientTexture1D:
	if _cache.has(field_name):
		return _cache[field_name]
	var stops: Array = STOPS.get(
		SAME_AS.get(field_name, field_name), [[0.0, "000000"], [1.0, "ffffff"]]
	)
	var lo: float = stops[0][0]
	var hi: float = stops[-1][0]
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array()
	grad.colors = PackedColorArray()
	for s in stops:
		grad.add_point((s[0] - lo) / (hi - lo), Color(s[1]))
	var tex := GradientTexture1D.new()
	tex.gradient = grad
	tex.width = 512
	_cache[field_name] = tex
	return tex
