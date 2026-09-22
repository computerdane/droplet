//! Column products from the reflectivity tilts of one volume, on a polar grid whose "range"
//! is ground distance from the radar (so a plan view draws them like a 0° sweep):
//!
//! - `CREF` composite reflectivity: the largest REF of any tilt above each ground point (dBZ).
//! - `ET` echo top: height of the `ECHO_TOP_DBZ` surface above the radar (km), interpolated in
//!   dBZ between the highest tilt at or above the threshold and the one above it (NWS
//!   enhanced-echo-tops style); the top tilt's beam height when even that one is above.
//! - `VIL` vertically integrated liquid (kg/m²): `3.44e-6 · Z^(4/7)` integrated over height
//!   between consecutive tilts, Z in mm⁶/m³ with reflectivity capped at `VIL_CAP_DBZ`.
//!
//! Beam heights and slant ranges use the 4/3 effective earth radius model, as the shaders do.

use std::collections::BTreeMap;

use crate::grid::{Grid, VALID_ABOVE};
use crate::level2::MISSING;
use crate::volume::{FieldMeta, Fields, SweepMeta};

pub const ECHO_TOP_DBZ: f32 = 18.0;
pub const VIL_CAP_DBZ: f32 = 56.0;
/// Reflectivity below this adds nothing to VIL (noise and clear air).
pub const VIL_MIN_DBZ: f32 = 0.0;
/// VIL below this is written as missing, so the plan view only shows precipitation.
pub const VIL_MIN_KG_M2: f32 = 0.1;
/// 4/3 of the earth's radius, km.
pub const KE_A_KM: f64 = 8494.67;
/// Sweeps closer than this in elevation are one tilt (split cuts, SAILS repeats), as in
/// `RadarVolume.tilts()` on the Godot side.
pub const ELEVATION_MERGE_DEG: f64 = 0.2;
pub const N_AZIMUTH_BINS: usize = 720;
pub const NAMES: [&str; 3] = ["CREF", "ET", "VIL"];

/// One reflectivity tilt as input.
pub struct TiltIn<'a> {
    pub grid: &'a Grid,
    pub elevation_deg: f64,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
}

/// Slant range (km) and height above the radar (km) of the beam at `elev_deg` over the
/// ground point `ground_km` away.
pub fn beam_at_ground(ground_km: f64, elev_deg: f64) -> (f64, f64) {
    let phi = ground_km / KE_A_KM;
    let th = elev_deg.to_radians();
    let r = KE_A_KM * phi.sin() / (th + phi).cos();
    let h = (r * r + KE_A_KM * KE_A_KM + 2.0 * r * KE_A_KM * th.sin()).sqrt() - KE_A_KM;
    (r, h)
}

/// Sweep indices with `field`, one per elevation, lowest first: of sweeps within
/// `ELEVATION_MERGE_DEG` of each other the one with the most gates, then the latest.
pub fn tilts(sweeps: &[SweepMeta], field: &str) -> Vec<usize> {
    let mut idx: Vec<usize> = (0..sweeps.len()).filter(|&i| sweeps[i].fields.contains_key(field)).collect();
    idx.sort_by(|&a, &b| sweeps[a].elevation_deg.total_cmp(&sweeps[b].elevation_deg));
    let gates = |i: usize| sweeps[i].fields[field].n_gates;
    let mut out: Vec<usize> = Vec::new();
    for i in idx {
        match out.last_mut() {
            Some(last) if sweeps[i].elevation_deg - sweeps[*last].elevation_deg < ELEVATION_MERGE_DEG => {
                if gates(i) > gates(*last) || (gates(i) == gates(*last) && i > *last) {
                    *last = i;
                }
            }
            _ => out.push(i),
        }
    }
    out
}

/// The three products on a grid of `N_AZIMUTH_BINS` rows and `n_gates` ground-range bins
/// centred at `first_gate_m + k * gate_spacing_m`. `tilts` must be sorted by elevation.
pub fn column_products(tilts: &[TiltIn], first_gate_m: f64, gate_spacing_m: f64, n_gates: usize) -> [Grid; 3] {
    let mut cref = Grid::filled(N_AZIMUTH_BINS, n_gates, MISSING);
    let mut top = Grid::filled(N_AZIMUTH_BINS, n_gates, MISSING);
    let mut vil = Grid::filled(N_AZIMUTH_BINS, n_gates, MISSING);
    // Per ground bin and tilt: the gate sampled and the beam height, shared by every row.
    let n_tilts = tilts.len();
    let mut gate_of = vec![usize::MAX; n_gates * n_tilts];
    let mut height_km = vec![0.0f64; n_gates * n_tilts];
    for g in 0..n_gates {
        let ground_km = (first_gate_m + g as f64 * gate_spacing_m) / 1000.0;
        for (k, t) in tilts.iter().enumerate() {
            let (r_km, h) = beam_at_ground(ground_km.max(0.0), t.elevation_deg);
            let gate = ((r_km * 1000.0 - t.first_gate_m) / t.gate_spacing_m).round();
            if gate >= 0.0 && (gate as usize) < t.grid.n_gates {
                gate_of[g * n_tilts + k] = gate as usize;
            }
            height_km[g * n_tilts + k] = h;
        }
    }
    let mut column = vec![MISSING; n_tilts];
    for row in 0..N_AZIMUTH_BINS {
        for g in 0..n_gates {
            for (k, t) in tilts.iter().enumerate() {
                let gate = gate_of[g * n_tilts + k];
                column[k] = if gate == usize::MAX { MISSING } else { t.grid.at(row * t.grid.n_az / N_AZIMUTH_BINS, gate) };
            }
            let h = &height_km[g * n_tilts..(g + 1) * n_tilts];
            let (c, e, v) = column_values(&column, h);
            cref.set(row, g, c);
            top.set(row, g, e);
            vil.set(row, g, v);
        }
    }
    [cref, top, vil]
}

/// CREF, ET and VIL of one column: `dbz[k]` and `h_km[k]` per tilt, lowest tilt first.
pub fn column_values(dbz: &[f32], h_km: &[f64]) -> (f32, f32, f32) {
    let valid = |v: f32| v > VALID_ABOVE;
    let cref = dbz.iter().copied().filter(|&v| valid(v)).fold(MISSING, f32::max);
    if !valid(cref) {
        return (MISSING, MISSING, MISSING);
    }
    let echo_top = match dbz.iter().rposition(|&v| valid(v) && v >= ECHO_TOP_DBZ) {
        None => MISSING,
        Some(k) if k + 1 < dbz.len() && valid(dbz[k + 1]) => {
            let f = ((dbz[k] - ECHO_TOP_DBZ) / (dbz[k] - dbz[k + 1])) as f64;
            (h_km[k] + f * (h_km[k + 1] - h_km[k])) as f32
        }
        Some(k) => h_km[k] as f32,
    };
    let z = |v: f32| if valid(v) && v >= VIL_MIN_DBZ { 10f64.powf(v.min(VIL_CAP_DBZ) as f64 / 10.0) } else { 0.0 };
    let mut vil = 0.0f64;
    for k in 0..dbz.len().saturating_sub(1) {
        let (za, zb) = (z(dbz[k]), z(dbz[k + 1]));
        if za > 0.0 || zb > 0.0 {
            vil += 3.44e-6 * (0.5 * (za + zb)).powf(4.0 / 7.0) * (h_km[k + 1] - h_km[k]) * 1000.0;
        }
    }
    let vil = if vil >= VIL_MIN_KG_M2 as f64 { vil as f32 } else { MISSING };
    (cref, echo_top, vil)
}

/// Product grids and their metadata (files `p_<NAME>.bin`) for a decoded volume, from its REF
/// tilts on the lowest tilt's gate spacing and reach; None without REF.
pub fn volume_products(sweeps: &[SweepMeta], grids: &[Fields]) -> Option<(ProductsMeta, Vec<Grid>)> {
    let ids = tilts(sweeps, "REF");
    let low = &sweeps[*ids.first()?].fields["REF"];
    let inputs: Vec<TiltIn> = ids
        .iter()
        .map(|&i| {
            let f = &sweeps[i].fields["REF"];
            TiltIn {
                grid: &grids[i]["REF"],
                elevation_deg: sweeps[i].elevation_deg,
                first_gate_m: f.first_gate_m as f64,
                gate_spacing_m: f.gate_spacing_m as f64,
            }
        })
        .collect();
    let out = column_products(&inputs, low.first_gate_m as f64, low.gate_spacing_m as f64, low.n_gates);
    let fields = NAMES
        .iter()
        .map(|&n| {
            let meta = FieldMeta {
                file: format!("p_{n}.bin"),
                n_gates: low.n_gates,
                first_gate_m: low.first_gate_m,
                gate_spacing_m: low.gate_spacing_m,
            };
            (n.to_string(), meta)
        })
        .collect();
    let meta = ProductsMeta { azimuth_step_deg: 360.0 / N_AZIMUTH_BINS as f64, n_azimuth_bins: N_AZIMUTH_BINS, fields };
    Some((meta, out.into()))
}

/// `products` in volume.json: laid out like a sweep (Godot treats it as one at 0°, with ground
/// distance for range), one field per product.
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct ProductsMeta {
    pub azimuth_step_deg: f64,
    pub n_azimuth_bins: usize,
    pub fields: BTreeMap<String, FieldMeta>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn beam_geometry_matches_the_forward_model() {
        // Forward: slant range r at elevation th -> ground distance and height.
        for (r, th) in [(50.0f64, 0.5f64), (150.0, 3.0), (230.0, 19.5), (10.0, 0.0)] {
            let t = th.to_radians();
            let h = (r * r + KE_A_KM * KE_A_KM + 2.0 * r * KE_A_KM * t.sin()).sqrt() - KE_A_KM;
            let s = KE_A_KM * (r * t.cos() / (KE_A_KM + r * t.sin())).atan();
            let (r2, h2) = beam_at_ground(s, th);
            assert!((r2 - r).abs() < 1e-6 && (h2 - h).abs() < 1e-6, "{r} {th}: {r2} {h2}");
        }
    }

    #[test]
    fn column_values_by_hand() {
        let h = [0.5, 1.5, 3.0, 6.0, 9.0];
        // Echo top between 6 km (28 dBZ) and 9 km (8 dBZ): 18 dBZ half way -> 7.5 km.
        let (c, e, v) = column_values(&[40.0, 45.0, 35.0, 28.0, 8.0], &h);
        assert_eq!(c, 45.0);
        assert!((e - 7.5).abs() < 1e-5, "{e}");
        let z = |d: f64| 10f64.powf(d / 10.0);
        let layer = |a: f64, b: f64, dh: f64| 3.44e-6 * (0.5 * (z(a) + z(b))).powf(4.0 / 7.0) * dh * 1000.0;
        let want = layer(40.0, 45.0, 1.0) + layer(45.0, 35.0, 1.5) + layer(35.0, 28.0, 3.0) + layer(28.0, 8.0, 3.0);
        assert!((v as f64 - want).abs() < 1e-3, "{v} {want}");
        // Top tilt still above the threshold: its beam height. Missing tilts are skipped for
        // CREF; a missing tilt above the top echo leaves the top at that tilt.
        assert_eq!(column_values(&[30.0, MISSING, 25.0, 20.0, 19.0], &h).1, 9.0);
        let (c, e, v) = column_values(&[30.0, 20.0, MISSING, MISSING, MISSING], &h);
        assert_eq!((c, e), (30.0, 1.5));
        let above = 3.44e-6 * (0.5 * z(20.0)).powf(4.0 / 7.0) * 1.5 * 1000.0; // 20 dBZ to nothing
        assert!((v as f64 - layer(30.0, 20.0, 1.0) - above).abs() < 1e-3, "{v}");
        // Hail cap: 70 dBZ counts as 56 in VIL, not in CREF.
        let (c, _, v) = column_values(&[70.0, 70.0], &h[..2]);
        assert_eq!(c, 70.0);
        assert!((v as f64 - layer(56.0, 56.0, 1.0)).abs() < 1e-3);
        // No echo: all missing; weak echo only: CREF but no top, no VIL.
        assert_eq!(column_values(&[MISSING, MISSING], &h[..2]), (MISSING, MISSING, MISSING));
        assert_eq!(column_values(&[-5.0, -10.0], &h[..2]), (-5.0, MISSING, MISSING));
    }

    #[test]
    fn tilt_selection_merges_split_cuts() {
        let sweep = |i: usize, elev: f64, gates: usize| {
            let mut fields = BTreeMap::new();
            fields.insert("REF".to_string(), FieldMeta { file: String::new(), n_gates: gates, first_gate_m: 0, gate_spacing_m: 250 });
            SweepMeta {
                index: i,
                elevation_number: 0,
                elevation_deg: elev,
                azimuth_step_deg: 0.5,
                n_azimuth_bins: 720,
                n_radials: 720,
                time: String::new(),
                nyquist_ms: None,
                unambiguous_range_km: None,
                fields,
            }
        };
        // Surveillance + Doppler cut at 0.5 (more gates wins), SAILS repeat at 0.48 (tie: latest).
        let sweeps = [sweep(0, 0.5, 1832), sweep(1, 0.51, 1192), sweep(2, 1.45, 1500), sweep(3, 0.48, 1832)];
        assert_eq!(tilts(&sweeps, "REF"), [3, 2]);
    }
}
