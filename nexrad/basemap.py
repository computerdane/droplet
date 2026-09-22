"""Basemap: US state/county outlines and city labels -> data/basemap/ for Godot.

Sources (public domain):
    US Census cartographic boundary files, 1:500k (states, counties), shapefile in a zip
    Natural Earth 10m populated places (GeoJSON)

Output, per line layer `<name>.bin` (little-endian):
    u32 n_points, u32 n_indices, f32[n_points][2] (lon, lat), u32[n_indices]
Indices are segment pairs for a PRIMITIVE_LINES mesh, so Godot can load the arrays as-is.
`basemap.json` lists the layers and the cities ([name, lat, lon, population]).
Projection to local km happens in Godot (shaders/basemap.gdshaderinc) around each site.
"""

from __future__ import annotations

import io
import json
import struct
import sys
import zipfile
from pathlib import Path

import numpy as np
import requests

CENSUS = "https://www2.census.gov/geo/tiger/GENZ2023/shp"
LAYERS = {
    "states": f"{CENSUS}/cb_2023_us_state_500k.zip",
    "counties": f"{CENSUS}/cb_2023_us_county_500k.zip",
}
CITIES_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
    "ne_10m_populated_places_simple.geojson"
)
# Natural Earth covers the world; keep North America around the NEXRAD network.
CITY_BOUNDS = (-170.0, 10.0, -50.0, 72.0)  # lon_min, lat_min, lon_max, lat_max
CITY_MIN_POP = 20_000


def fetch(url: str, cache_dir: Path) -> bytes:
    cache_dir.mkdir(parents=True, exist_ok=True)
    dest = cache_dir / url.rsplit("/", 1)[-1]
    if not dest.exists():
        print(f"downloading {url}", file=sys.stderr)
        r = requests.get(url, timeout=120)
        r.raise_for_status()
        tmp = dest.with_suffix(dest.suffix + ".tmp")
        tmp.write_bytes(r.content)
        tmp.replace(dest)
    return dest.read_bytes()


def read_shp_rings(shp: bytes) -> list[np.ndarray]:
    """All polygon rings / polyline parts in an ESRI .shp as (n, 2) float64 lon/lat arrays."""
    rings: list[np.ndarray] = []
    pos = 100  # fixed file header
    while pos + 8 <= len(shp):
        _, words = struct.unpack(">ii", shp[pos : pos + 8])
        content = shp[pos + 8 : pos + 8 + words * 2]
        pos += 8 + words * 2
        (shape_type,) = struct.unpack("<i", content[:4])
        if shape_type not in (3, 5, 13, 15, 23, 25):  # polyline / polygon (+Z/M variants)
            continue
        n_parts, n_points = struct.unpack("<ii", content[36:44])
        parts = np.frombuffer(content, "<i4", n_parts, 44)
        pts = np.frombuffer(content, "<f8", n_points * 2, 44 + 4 * n_parts).reshape(-1, 2)
        bounds = list(parts) + [n_points]
        for a, b in zip(bounds[:-1], bounds[1:]):
            if b - a >= 2:
                rings.append(pts[a:b])
    return rings


def pack_lines(rings: list[np.ndarray]) -> bytes:
    xy = np.concatenate(rings).astype("<f4")
    idx = []
    start = 0
    for r in rings:
        i = np.arange(start, start + len(r) - 1, dtype="<u4")
        idx.append(np.stack([i, i + 1], axis=1).ravel())
        start += len(r)
    indices = np.concatenate(idx).astype("<u4")
    return struct.pack("<II", len(xy), len(indices)) + xy.tobytes() + indices.tobytes()


def shapefile_from_zip(blob: bytes) -> bytes:
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        name = next(n for n in z.namelist() if n.endswith(".shp"))
        return z.read(name)


def cities(blob: bytes) -> list[list]:
    lon0, lat0, lon1, lat1 = CITY_BOUNDS
    out = []
    for f in json.loads(blob)["features"]:
        p = f["properties"]
        lon, lat = f["geometry"]["coordinates"][:2]
        pop = int(p.get("pop_max") or 0)
        if lon0 <= lon <= lon1 and lat0 <= lat <= lat1 and pop >= CITY_MIN_POP:
            out.append([p["name"], round(lat, 5), round(lon, 5), pop])
    out.sort(key=lambda c: -c[3])
    return out


def build(out_dir: Path, cache_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    layers = {}
    for name, url in LAYERS.items():
        rings = read_shp_rings(shapefile_from_zip(fetch(url, cache_dir)))
        data = pack_lines(rings)
        tmp = out_dir / f"{name}.bin.tmp"
        tmp.write_bytes(data)
        tmp.replace(out_dir / f"{name}.bin")
        n_points = sum(len(r) for r in rings)
        layers[name] = {"file": f"{name}.bin", "n_lines": len(rings), "n_points": n_points}
        print(f"{name}: {len(rings)} lines, {n_points} points, {len(data) >> 10} KiB", file=sys.stderr)
    places = cities(fetch(CITIES_URL, cache_dir))
    print(f"cities: {len(places)}", file=sys.stderr)
    meta = {"format_version": 1, "layers": layers, "cities": places}
    tmp = out_dir / "basemap.json.tmp"
    tmp.write_text(json.dumps(meta))
    tmp.replace(out_dir / "basemap.json")
    return out_dir
