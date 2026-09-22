//! Basemap: US state/county outlines and city labels -> data/basemap/ for Godot.
//!
//! Sources (public domain):
//!     US Census cartographic boundary files, 1:500k (states, counties), shapefile in a zip
//!     Natural Earth 10m populated places (GeoJSON)
//!
//! Output, per line layer `<name>.bin` (little-endian):
//!     u32 n_points, u32 n_indices, f32[n_points][2] (lon, lat), u32[n_indices]
//! Indices are segment pairs for a PRIMITIVE_LINES mesh, so Godot can load the arrays as-is.
//! `basemap.json` lists the layers and the cities ([name, lat, lon, population]).
//! Projection to local km happens in Godot (shaders/basemap.gdshaderinc) around each site.

use std::io::Read;
#[cfg(feature = "native")]
use std::path::{Path, PathBuf};

#[cfg(feature = "native")]
use serde_json::Map;
use serde_json::{Value, json};

#[cfg(feature = "native")]
use crate::volume::write_atomic;
use crate::{Error, Result};

#[cfg(feature = "native")]
const CENSUS: &str = "https://www2.census.gov/geo/tiger/GENZ2023/shp";
pub const LAYERS: &[(&str, &str)] = &[("states", "cb_2023_us_state_500k.zip"), ("counties", "cb_2023_us_county_500k.zip")];
pub const CITIES_URL: &str =
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_10m_populated_places_simple.geojson";
/// Natural Earth covers the world; keep North America around the NEXRAD network:
/// lon_min, lat_min, lon_max, lat_max.
pub const CITY_BOUNDS: (f64, f64, f64, f64) = (-170.0, 10.0, -50.0, 72.0);
pub const CITY_MIN_POP: i64 = 20_000;

fn le_u32(b: &[u8], at: usize) -> Option<u32> {
    b.get(at..at + 4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}
fn le_i32(b: &[u8], at: usize) -> Option<i32> {
    le_u32(b, at).map(|v| v as i32)
}
fn le_u16(b: &[u8], at: usize) -> Option<u16> {
    b.get(at..at + 2).map(|s| u16::from_le_bytes([s[0], s[1]]))
}
fn le_f64(b: &[u8], at: usize) -> Option<f64> {
    b.get(at..at + 8).map(|s| f64::from_le_bytes(s.try_into().unwrap()))
}

/// All polygon rings / polyline parts in an ESRI .shp as (lon, lat) point lists.
pub fn read_shp_rings(shp: &[u8]) -> Vec<Vec<[f64; 2]>> {
    let mut rings = Vec::new();
    let mut pos = 100; // fixed file header
    while pos + 8 <= shp.len() {
        let words = u32::from_be_bytes([shp[pos + 4], shp[pos + 5], shp[pos + 6], shp[pos + 7]]) as usize;
        let Some(content) = shp.get(pos + 8..pos + 8 + words * 2) else { break };
        pos += 8 + words * 2;
        let Some(shape_type) = le_i32(content, 0) else { break };
        if ![3, 5, 13, 15, 23, 25].contains(&shape_type) {
            continue; // polyline / polygon (+Z/M variants) only
        }
        let (Some(n_parts), Some(n_points)) = (le_i32(content, 36), le_i32(content, 40)) else { continue };
        let (n_parts, n_points) = (n_parts.max(0) as usize, n_points.max(0) as usize);
        let parts: Vec<usize> = (0..n_parts).filter_map(|i| le_i32(content, 44 + 4 * i).map(|p| p.max(0) as usize)).collect();
        let base = 44 + 4 * n_parts;
        let pts: Vec<[f64; 2]> =
            (0..n_points).filter_map(|i| Some([le_f64(content, base + 16 * i)?, le_f64(content, base + 16 * i + 8)?])).collect();
        let mut bounds = parts.clone();
        bounds.push(pts.len());
        for w in bounds.windows(2) {
            let (a, b) = (w[0].min(pts.len()), w[1].min(pts.len()));
            if b >= a + 2 {
                rings.push(pts[a..b].to_vec());
            }
        }
    }
    rings
}

/// The `.bin` layout: point count, index count, f32 lon/lat pairs, u32 segment indices.
pub fn pack_lines(rings: &[Vec<[f64; 2]>]) -> Vec<u8> {
    let n_points: usize = rings.iter().map(Vec::len).sum();
    let n_indices: usize = rings.iter().map(|r| (r.len() - 1) * 2).sum();
    let mut out = Vec::with_capacity(8 + n_points * 8 + n_indices * 4);
    out.extend_from_slice(&(n_points as u32).to_le_bytes());
    out.extend_from_slice(&(n_indices as u32).to_le_bytes());
    for r in rings {
        for p in r {
            out.extend_from_slice(&(p[0] as f32).to_le_bytes());
            out.extend_from_slice(&(p[1] as f32).to_le_bytes());
        }
    }
    let mut start = 0u32;
    for r in rings {
        for i in 0..r.len() as u32 - 1 {
            out.extend_from_slice(&(start + i).to_le_bytes());
            out.extend_from_slice(&(start + i + 1).to_le_bytes());
        }
        start += r.len() as u32;
    }
    out
}

/// The first `.shp` member of a zip archive (stored or deflated; no zip64).
pub fn shapefile_from_zip(blob: &[u8]) -> Result<Vec<u8>> {
    // End of central directory: signature 0x06054b50, scanned back from the end.
    let eocd = (0..blob.len().saturating_sub(21))
        .rev()
        .map(|i| blob.len() - 22 - i)
        .find(|&i| le_u32(blob, i) == Some(0x0605_4b50))
        .ok_or("zip: no central directory")?;
    let n = le_u16(blob, eocd + 10).ok_or("zip: short")? as usize;
    let mut pos = le_u32(blob, eocd + 16).ok_or("zip: short")? as usize;
    for _ in 0..n {
        if le_u32(blob, pos) != Some(0x0201_4b50) {
            return Err("zip: bad central directory entry".into());
        }
        let method = le_u16(blob, pos + 10).ok_or("zip: short")?;
        let csize = le_u32(blob, pos + 20).ok_or("zip: short")? as usize;
        let name_len = le_u16(blob, pos + 28).ok_or("zip: short")? as usize;
        let extra_len = le_u16(blob, pos + 30).ok_or("zip: short")? as usize;
        let comment_len = le_u16(blob, pos + 32).ok_or("zip: short")? as usize;
        let local = le_u32(blob, pos + 42).ok_or("zip: short")? as usize;
        let name = String::from_utf8_lossy(blob.get(pos + 46..pos + 46 + name_len).ok_or("zip: short")?).to_string();
        pos += 46 + name_len + extra_len + comment_len;
        if !name.ends_with(".shp") {
            continue;
        }
        if le_u32(blob, local) != Some(0x0403_4b50) {
            return Err("zip: bad local header".into());
        }
        let lname = le_u16(blob, local + 26).ok_or("zip: short")? as usize;
        let lextra = le_u16(blob, local + 28).ok_or("zip: short")? as usize;
        let start = local + 30 + lname + lextra;
        let data = blob.get(start..start + csize).ok_or("zip: truncated member")?;
        return match method {
            0 => Ok(data.to_vec()),
            8 => {
                let mut out = Vec::new();
                flate2::read::DeflateDecoder::new(data).read_to_end(&mut out).map_err(|e| Error::from(format!("zip: {name}: {e}")))?;
                Ok(out)
            }
            m => Err(format!("zip: {name}: unsupported compression method {m}").into()),
        };
    }
    Err("zip: no .shp member".into())
}

/// `[name, lat, lon, population]` for every Natural Earth place in bounds above the
/// population cut, largest first.
pub fn cities(geojson: &[u8]) -> Result<Vec<Value>> {
    let (lon0, lat0, lon1, lat1) = CITY_BOUNDS;
    let doc: Value = serde_json::from_slice(geojson)?;
    let mut out: Vec<(String, f64, f64, i64)> = Vec::new();
    for f in doc["features"].as_array().ok_or("geojson: no features")? {
        let p = &f["properties"];
        let c = &f["geometry"]["coordinates"];
        let (Some(lon), Some(lat)) = (c[0].as_f64(), c[1].as_f64()) else { continue };
        let pop = p["pop_max"].as_f64().unwrap_or(0.0) as i64;
        if (lon0..=lon1).contains(&lon) && (lat0..=lat1).contains(&lat) && pop >= CITY_MIN_POP {
            let name = p["name"].as_str().unwrap_or("").to_string();
            out.push((name, crate::round_to(lat, 5), crate::round_to(lon, 5), pop));
        }
    }
    out.sort_by_key(|c| std::cmp::Reverse(c.3));
    Ok(out.into_iter().map(|(n, lat, lon, pop)| json!([n, lat, lon, pop])).collect())
}

/// Downloads `url` into `cache_dir` once and returns its bytes.
#[cfg(feature = "native")]
pub fn fetch(url: &str, cache_dir: &Path, log: &mut dyn std::io::Write) -> Result<Vec<u8>> {
    std::fs::create_dir_all(cache_dir)?;
    let dest = cache_dir.join(url.rsplit('/').next().unwrap_or("download"));
    if !dest.exists() {
        let _ = writeln!(log, "downloading {url}");
        write_atomic(&dest, &crate::net::get_bytes(url)?)?;
    }
    Ok(std::fs::read(&dest)?)
}

/// Builds `data/basemap` from the cached (or freshly downloaded) sources.
#[cfg(feature = "native")]
pub fn build(out_dir: &Path, cache_dir: &Path, log: &mut dyn std::io::Write) -> Result<PathBuf> {
    std::fs::create_dir_all(out_dir)?;
    let mut layers = Map::new();
    for &(name, file) in LAYERS {
        let rings = read_shp_rings(&shapefile_from_zip(&fetch(&format!("{CENSUS}/{file}"), cache_dir, log)?)?);
        let data = pack_lines(&rings);
        write_atomic(&out_dir.join(format!("{name}.bin")), &data)?;
        let n_points: usize = rings.iter().map(Vec::len).sum();
        layers.insert(name.into(), json!({"file": format!("{name}.bin"), "n_lines": rings.len(), "n_points": n_points}));
        let _ = writeln!(log, "{name}: {} lines, {n_points} points, {} KiB", rings.len(), data.len() >> 10);
    }
    let places = cities(&fetch(CITIES_URL, cache_dir, log)?)?;
    let _ = writeln!(log, "cities: {}", places.len());
    let meta = json!({"format_version": 1, "layers": layers, "cities": places});
    write_atomic(&out_dir.join("basemap.json"), serde_json::to_string(&meta)?.as_bytes())?;
    Ok(out_dir.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A one-record polygon shapefile with two rings.
    fn shp(rings: &[Vec<[f64; 2]>]) -> Vec<u8> {
        let n_points: usize = rings.iter().map(Vec::len).sum();
        let mut content = Vec::new();
        content.extend_from_slice(&5i32.to_le_bytes());
        content.extend_from_slice(&[0u8; 32]); // bbox
        content.extend_from_slice(&(rings.len() as i32).to_le_bytes());
        content.extend_from_slice(&(n_points as i32).to_le_bytes());
        let mut start = 0i32;
        for r in rings {
            content.extend_from_slice(&start.to_le_bytes());
            start += r.len() as i32;
        }
        for p in rings.iter().flatten() {
            content.extend_from_slice(&p[0].to_le_bytes());
            content.extend_from_slice(&p[1].to_le_bytes());
        }
        let mut out = vec![0u8; 100];
        out.extend_from_slice(&1i32.to_be_bytes());
        out.extend_from_slice(&((content.len() / 2) as i32).to_be_bytes());
        out.extend_from_slice(&content);
        out
    }

    #[test]
    fn rings_and_packing() {
        let rings = vec![vec![[-97.0, 35.0], [-96.0, 35.0], [-96.0, 36.0], [-97.0, 35.0]], vec![[-90.0, 40.0], [-91.0, 41.0]]];
        let got = read_shp_rings(&shp(&rings));
        assert_eq!(got, rings);
        let packed = pack_lines(&got);
        assert_eq!(le_u32(&packed, 0), Some(6));
        assert_eq!(le_u32(&packed, 4), Some(8));
        assert_eq!(packed.len(), 8 + 6 * 8 + 8 * 4);
        let idx: Vec<u32> = (0..8).map(|i| le_u32(&packed, 8 + 48 + 4 * i).unwrap()).collect();
        assert_eq!(idx, [0, 1, 1, 2, 2, 3, 4, 5]);
    }

    #[test]
    fn zip_and_cities() {
        // A stored zip with one .shp member.
        let payload = b"shapefile bytes".to_vec();
        let name = b"cb_test.shp";
        let mut z = Vec::new();
        let local = 0u32;
        z.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        z.extend_from_slice(&[0u8; 4]); // version, flags
        z.extend_from_slice(&0u16.to_le_bytes()); // stored
        z.extend_from_slice(&[0u8; 8]); // time, date, crc
        z.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        z.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        z.extend_from_slice(&(name.len() as u16).to_le_bytes());
        z.extend_from_slice(&0u16.to_le_bytes());
        z.extend_from_slice(name);
        z.extend_from_slice(&payload);
        let cd = z.len() as u32;
        z.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        z.extend_from_slice(&[0u8; 6]);
        z.extend_from_slice(&0u16.to_le_bytes());
        z.extend_from_slice(&[0u8; 8]);
        z.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        z.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        z.extend_from_slice(&(name.len() as u16).to_le_bytes());
        z.extend_from_slice(&[0u8; 12]); // extra, comment, disk, attrs
        z.extend_from_slice(&local.to_le_bytes());
        z.extend_from_slice(name);
        let cd_len = z.len() as u32 - cd;
        z.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        z.extend_from_slice(&[0u8; 4]);
        z.extend_from_slice(&1u16.to_le_bytes());
        z.extend_from_slice(&1u16.to_le_bytes());
        z.extend_from_slice(&cd_len.to_le_bytes());
        z.extend_from_slice(&cd.to_le_bytes());
        z.extend_from_slice(&0u16.to_le_bytes());
        assert_eq!(shapefile_from_zip(&z).unwrap(), payload);
        assert!(shapefile_from_zip(b"not a zip").is_err());

        let geo = json!({"features": [
            {"properties": {"name": "Norman", "pop_max": 110000}, "geometry": {"coordinates": [-97.44, 35.22]}},
            {"properties": {"name": "Oklahoma City", "pop_max": 650000}, "geometry": {"coordinates": [-97.52, 35.47]}},
            {"properties": {"name": "Tiny", "pop_max": 500}, "geometry": {"coordinates": [-97.0, 35.0]}},
            {"properties": {"name": "Paris", "pop_max": 2000000}, "geometry": {"coordinates": [2.35, 48.86]}},
        ]});
        let c = cities(serde_json::to_string(&geo).unwrap().as_bytes()).unwrap();
        assert_eq!(c, vec![json!(["Oklahoma City", 35.47, -97.52, 650000]), json!(["Norman", 35.22, -97.44, 110000])]);
    }
}
