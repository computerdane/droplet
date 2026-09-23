//! Hydrometeor classification (`HCA`), a per-gate field written next to the dual-pol moments,
//! and the melting layer it depends on.
//!
//! The classifier is the fuzzy-logic scheme of the WSR-88D HCA (Park et al. 2009, Wea.
//! Forecasting 24): each class scores every gate with trapezoidal membership functions of Z,
//! ZDR, ρhv, 10 log KDP and the textures SD(Z) / SD(ΦDP) (ZDR and KDP bounds of the rain and
//! hail classes grow with Z), weighted per class; the classes the beam's position relative
//! to the melting layer rules out are dropped, and the best score wins. Below
//! `MIN_SCORE` the gate is `UK` (unknown). Values are class codes 1..=11 (`CLASSES`), exact
//! in float16.
//!
//! The melting layer comes from the data when it shows one (the MLDA idea of Giangrande et
//! al. 2008: gates of the moderately-elevated tilts with ρhv 0.90–0.97, Z 30–47 dBZ and ZDR
//! 0.8–2.5 dB mark the bright band; their height percentiles give its bottom and top),
//! otherwise from a latitude/season climatology of the 0 °C height, labelled as such.

use serde::{Deserialize, Serialize};

use crate::grid::{Grid, VALID_ABOVE};
use crate::level2::MISSING;
use crate::time::Utc;
use crate::vad::beam_height_m;

/// Class abbreviations; a gate's value is the index + 1.
pub const CLASSES: [&str; 11] = ["GC", "BS", "DS", "WS", "CR", "GR", "BD", "RA", "HR", "RH", "UK"];
const GC: usize = 0;
const BS: usize = 1;
const DS: usize = 2;
const WS: usize = 3;
const CR: usize = 4;
const GR: usize = 5;
const BD: usize = 6;
const RA: usize = 7;
const HR: usize = 8;
const RH: usize = 9;
const UK: usize = 10;
const N: usize = 10; // scored classes (all but UK)

/// Best aggregated score below which a gate is unknown.
pub const MIN_SCORE: f64 = 0.5;
/// Ground clutter / AP only on tilts at or below this elevation.
pub const CLUTTER_MAX_ELEVATION_DEG: f64 = 1.6;
/// Half-power beam width used for the beam's top and bottom.
pub const BEAM_WIDTH_DEG: f64 = 0.95;
/// Half windows along the radial: Z / ZDR / ρhv averaging and SD(Z) over ±0.5 km, SD(ΦDP) over ±1 km.
pub const HALF_WINDOW_M: (f64, f64) = (500.0, 1000.0);

/// Tilts searched for the bright band, their slant range and the gate criteria.
pub const ML_ELEVATIONS_DEG: (f64, f64) = (3.5, 10.5);
pub const ML_RANGE_M: (f64, f64) = (5_000.0, 80_000.0);
pub const ML_RHO: (f32, f32) = (0.90, 0.97);
pub const ML_DBZ: (f32, f32) = (30.0, 47.0);
pub const ML_ZDR: (f32, f32) = (0.8, 2.5);
/// A detection needs this many gates, all within an interquartile range of `ML_MAX_IQR_M`
/// (bright-band gates lie in a thin layer; convective cores scatter them over kilometres).
pub const ML_MIN_GATES: usize = 300;
pub const ML_MAX_IQR_M: f64 = 1000.0;
/// Thickness below the 0 °C level a climatological melting layer gets.
pub const ML_CLIMATOLOGY_DEPTH_M: f64 = 600.0;

/// Bottom and top of the melting layer in metres above the radar.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct MeltingLayer {
    pub bottom_m: f64,
    pub top_m: f64,
    /// "detected" (from this volume's bright band) or "climatology".
    pub source: String,
    /// Bright-band gates behind a detection (0 for climatology).
    pub n: usize,
}

/// One tilt with the moments the melting layer detection and the classifier read, each
/// with its own gate geometry (REF often reaches further than the dual-pol moments).
pub struct SweepIn<'a> {
    pub elevation_deg: f64,
    pub refl: Moment<'a>,
    pub zdr: Moment<'a>,
    pub rho: Moment<'a>,
    pub phi: Option<Moment<'a>>,
    pub kdp: Option<Moment<'a>>,
}

#[derive(Clone, Copy)]
pub struct Moment<'a> {
    pub grid: &'a Grid,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
}

impl Moment<'_> {
    /// The value at slant range `r` (m) on azimuth row `a` of an `n_az`-row sweep, MISSING
    /// outside the grid.
    #[inline]
    fn at_range(&self, a: usize, n_az: usize, r: f64) -> f32 {
        let g = ((r - self.first_gate_m) / self.gate_spacing_m).round();
        if g < 0.0 || g >= self.grid.n_gates as f64 {
            return MISSING;
        }
        self.grid.at(a * self.grid.n_az / n_az, g as usize)
    }
}

/// The melting layer from the bright band of `sweeps`, if they show one.
pub fn detect_melting_layer(sweeps: &[SweepIn]) -> Option<MeltingLayer> {
    let mut heights: Vec<f64> = Vec::new();
    for s in sweeps {
        if s.elevation_deg < ML_ELEVATIONS_DEG.0 || s.elevation_deg > ML_ELEVATIONS_DEG.1 {
            continue;
        }
        let (n_az, rho) = (s.rho.grid.n_az, s.rho);
        for g in 0..rho.grid.n_gates {
            let r = rho.first_gate_m + g as f64 * rho.gate_spacing_m;
            if r < ML_RANGE_M.0 || r > ML_RANGE_M.1 {
                continue;
            }
            let h = beam_height_m(r, s.elevation_deg);
            for a in 0..n_az {
                let c = rho.grid.at(a, g);
                if c < ML_RHO.0 || c > ML_RHO.1 {
                    continue;
                }
                let (z, d) = (s.refl.at_range(a, n_az, r), s.zdr.at_range(a, n_az, r));
                if (ML_DBZ.0..=ML_DBZ.1).contains(&z) && (ML_ZDR.0..=ML_ZDR.1).contains(&d) {
                    heights.push(h);
                }
            }
        }
    }
    if heights.len() < ML_MIN_GATES {
        return None;
    }
    heights.sort_by(f64::total_cmp);
    let pct = |p: f64| heights[((heights.len() - 1) as f64 * p).round() as usize];
    if pct(0.75) - pct(0.25) > ML_MAX_IQR_M {
        return None;
    }
    // The beam smears the layer by its width: the 10th / 90th percentiles sit inside the
    // layer's edges by about as much as the outliers outside them would add.
    Some(MeltingLayer { bottom_m: pct(0.1).round(), top_m: pct(0.9).round(), source: "detected".into(), n: heights.len() })
}

/// The 0 °C height (m above sea level) of a mid-latitude climatology: highest in late July,
/// with a mean that falls and a seasonal swing that grows poleward (about 3.3 ± 1.4 km at
/// 35°N, 2.5 ± 1.9 km at 45°N). A last resort when the data show no bright band.
pub fn climatological_freezing_level_m(latitude_deg: f64, time: Utc) -> f64 {
    let lat = latitude_deg.abs().clamp(10.0, 70.0);
    let mean = 5900.0 - 75.0 * lat;
    let swing = (50.0 * lat - 350.0).clamp(300.0, 1900.0);
    let day = time.days() as f64 % 365.2425;
    let phase = std::f64::consts::TAU * (day - 205.0) / 365.2425;
    let season = if latitude_deg < 0.0 { -phase.cos() } else { phase.cos() };
    (mean + swing * season).max(0.0)
}

/// The melting layer of a climatological freezing level, relative to a radar at `radar_height_m`.
pub fn climatological_melting_layer(latitude_deg: f64, time: Utc, radar_height_m: f64) -> MeltingLayer {
    let top = (climatological_freezing_level_m(latitude_deg, time) - radar_height_m).round();
    MeltingLayer { bottom_m: top - ML_CLIMATOLOGY_DEPTH_M, top_m: top, source: "climatology".into(), n: 0 }
}

/// Trapezoid membership: 0 outside [x1, x4], 1 on [x2, x3], linear between.
#[inline]
fn trap(x: f64, [x1, x2, x3, x4]: [f64; 4]) -> f64 {
    if x < x1 || x > x4 {
        0.0
    } else if x < x2 {
        (x - x1) / (x2 - x1)
    } else if x <= x3 {
        1.0
    } else {
        (x4 - x) / (x4 - x3)
    }
}

/// Variables of one gate: Z (dBZ), ZDR (dB), ρhv, 10 log KDP, SD(Z) (dB), SD(ΦDP) (°);
/// None where unavailable (the term is left out of the score).
#[derive(Clone, Copy, Debug)]
pub struct Gate {
    pub z: f64,
    pub zdr: f64,
    pub rho: f64,
    pub lkdp: Option<f64>,
    pub sd_z: Option<f64>,
    pub sd_phi: Option<f64>,
}

/// 10 log10 KDP, with KDP ≤ 0.001 °/km as -30.
pub fn lkdp(kdp: f64) -> f64 {
    if kdp > 0.001 { 10.0 * kdp.log10() } else { -30.0 }
}

/// Weights of Z, ZDR, ρhv, LKDP, SD(Z), SD(ΦDP) per class (Park et al. 2009, table 2).
const WEIGHTS: [[f64; 6]; N] = [
    [0.2, 0.4, 1.0, 0.0, 0.6, 0.8], // GC
    [0.4, 0.6, 1.0, 0.0, 0.8, 0.8], // BS
    [1.0, 0.8, 0.6, 0.0, 0.2, 0.2], // DS
    [0.6, 0.8, 1.0, 0.0, 0.2, 0.2], // WS
    [1.0, 0.6, 0.4, 0.5, 0.2, 0.2], // CR
    [0.8, 1.0, 0.4, 0.0, 0.2, 0.2], // GR
    [0.8, 1.0, 0.6, 0.0, 0.2, 0.2], // BD
    [1.0, 0.8, 0.6, 0.0, 0.2, 0.2], // RA
    [1.0, 0.8, 0.6, 1.0, 0.2, 0.2], // HR
    [1.0, 0.8, 0.6, 1.0, 0.2, 0.2], // RH
];

/// Membership bounds [x1..x4] of class `c` for variable `v` (0 Z, 1 ZDR, 2 ρhv, 3 LKDP,
/// 4 SD(Z), 5 SD(ΦDP)) at reflectivity `z` (Park et al. 2009, table 1).
fn bounds(c: usize, v: usize, z: f64) -> [f64; 4] {
    let f1 = -0.50 + 2.50e-3 * z + 7.50e-4 * z * z;
    let f2 = 0.68 - 4.81e-2 * z + 2.92e-3 * z * z;
    let f3 = 1.42 + 6.67e-2 * z + 4.85e-4 * z * z;
    let g1 = -44.0 + 0.8 * z;
    let g2 = -22.0 + 0.5 * z;
    match (v, c) {
        (0, GC) => [15.0, 20.0, 70.0, 80.0],
        (0, BS) => [5.0, 10.0, 20.0, 30.0],
        (0, DS) => [5.0, 10.0, 35.0, 40.0],
        (0, WS) => [25.0, 30.0, 40.0, 50.0],
        (0, CR) => [0.0, 5.0, 20.0, 25.0],
        (0, GR) => [25.0, 35.0, 50.0, 55.0],
        (0, BD) => [20.0, 25.0, 45.0, 50.0],
        (0, RA) => [5.0, 10.0, 45.0, 50.0],
        (0, HR) => [40.0, 45.0, 55.0, 60.0],
        (0, RH) => [45.0, 50.0, 75.0, 80.0],
        (1, GC) => [-4.0, -2.0, 1.0, 2.0],
        (1, BS) => [0.0, 2.0, 10.0, 12.0],
        (1, DS) => [-0.3, 0.0, 0.3, 0.6],
        (1, WS) => [0.5, 1.0, 2.0, 3.0],
        (1, CR) => [0.1, 0.4, 3.0, 3.3],
        (1, GR) => [-0.3, 0.0, f1, f1 + 0.3],
        (1, BD) => [f2 - 0.3, f2, f3, f3 + 1.0],
        (1, RA) | (1, HR) => [f1 - 0.3, f1, f2, f2 + 0.5],
        (1, RH) => [-0.3, 0.0, f1, f1 + 0.5],
        (2, GC) => [0.5, 0.6, 0.9, 0.95],
        (2, BS) => [0.3, 0.5, 0.8, 0.83],
        (2, DS) | (2, CR) | (2, RA) => [0.95, 0.98, 1.0, 1.01],
        (2, WS) => [0.88, 0.92, 0.95, 0.985],
        (2, GR) => [0.90, 0.97, 1.0, 1.01],
        (2, BD) | (2, HR) => [0.92, 0.95, 1.0, 1.01],
        (2, RH) => [0.85, 0.90, 1.0, 1.01],
        (3, CR) => [-5.0, 0.0, 10.0, 15.0],
        (3, BD) | (3, RA) | (3, HR) => [g1 - 1.0, g1, g2, g2 + 1.0],
        (3, RH) => [-10.0, -4.0, g1, g1 + 1.0],
        (3, BS) => [-30.0, -25.0, 10.0, 10.0],
        (3, _) => [-30.0, -25.0, 10.0, 20.0],
        (4, GC) => [2.0, 4.0, 10.0, 15.0],
        (4, BS) => [1.0, 2.0, 4.0, 7.0],
        (4, _) => [0.0, 0.5, 3.0, 6.0],
        (5, GC) => [30.0, 40.0, 50.0, 60.0],
        (5, BS) => [8.0, 10.0, 40.0, 60.0],
        (5, _) => [0.0, 1.0, 15.0, 30.0],
        _ => unreachable!(),
    }
}

/// Where the beam is relative to the melting layer.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layer {
    Below,
    Within,
    Above,
}

/// The beam (±½ `BEAM_WIDTH_DEG`) at slant range `r` against the melting layer.
pub fn layer_at(r: f64, elevation_deg: f64, ml: &MeltingLayer) -> Layer {
    let top = beam_height_m(r, elevation_deg + BEAM_WIDTH_DEG / 2.0);
    let bottom = beam_height_m(r, elevation_deg - BEAM_WIDTH_DEG / 2.0);
    if top <= ml.bottom_m {
        Layer::Below
    } else if bottom >= ml.top_m {
        Layer::Above
    } else {
        Layer::Within
    }
}

/// Classes that can occur in `layer` (Park et al. 2009, section 3c).
fn allowed(c: usize, layer: Layer, clutter_tilt: bool) -> bool {
    match layer {
        Layer::Below => matches!(c, BS | BD | RA | HR | RH) || (c == GC && clutter_tilt),
        Layer::Within => matches!(c, BS | DS | WS | GR | BD | RA | HR | RH) || (c == GC && clutter_tilt),
        Layer::Above => matches!(c, DS | CR | GR | RH),
    }
}

/// The class index (into `CLASSES`) of one gate.
pub fn classify_gate(g: &Gate, layer: Layer, clutter_tilt: bool) -> usize {
    let vars = [Some(g.z), Some(g.zdr), Some(g.rho), g.lkdp, g.sd_z, g.sd_phi];
    let (mut best, mut best_score) = (UK, MIN_SCORE);
    for (c, weights) in WEIGHTS.iter().enumerate() {
        if !allowed(c, layer, clutter_tilt) {
            continue;
        }
        let (mut sum, mut wsum) = (0.0, 0.0);
        for (v, (x, &w)) in vars.iter().zip(weights).enumerate() {
            if let (Some(x), true) = (x, w > 0.0) {
                sum += w * trap(*x, bounds(c, v, g.z));
                wsum += w;
            }
        }
        let score = sum / wsum;
        if score > best_score {
            (best, best_score) = (c, score);
        }
    }
    best
}

/// Mean (dB domain) and standard deviation of the valid values of `row` within `half` gates
/// of `g`; None with fewer than half of the window valid.
fn window_stats(row: &[f32], g: usize, half: usize) -> Option<(f64, f64)> {
    let (lo, hi) = (g.saturating_sub(half), (g + half + 1).min(row.len()));
    let (mut s, mut ss, mut n) = (0.0, 0.0, 0usize);
    for &v in &row[lo..hi] {
        if v > VALID_ABOVE {
            let v = v as f64;
            (s, ss, n) = (s + v, ss + v * v, n + 1);
        }
    }
    if n * 2 < hi - lo {
        return None;
    }
    let mean = s / n as f64;
    Some((mean, (ss / n as f64 - mean * mean).max(0.0).sqrt()))
}

/// Standard deviation of ΦDP within `half` gates of `g`, about the centre gate's phase
/// (differences wrapped to ±180°).
fn phi_texture(row: &[f32], g: usize, half: usize) -> Option<f64> {
    let p0 = row[g];
    if p0 <= VALID_ABOVE {
        return None;
    }
    let (lo, hi) = (g.saturating_sub(half), (g + half + 1).min(row.len()));
    let (mut s, mut ss, mut n) = (0.0, 0.0, 0usize);
    for &p in &row[lo..hi] {
        if p > VALID_ABOVE {
            let d = ((p - p0) as f64 + 180.0).rem_euclid(360.0) - 180.0;
            (s, ss, n) = (s + d, ss + d * d, n + 1);
        }
    }
    if n * 2 < hi - lo {
        return None;
    }
    let mean = s / n as f64;
    Some((ss / n as f64 - mean * mean).max(0.0).sqrt())
}

/// HCA of one sweep on the ZDR grid's geometry (MISSING where Z, ZDR or ρhv is missing).
pub fn classify(s: &SweepIn, ml: &MeltingLayer) -> Grid {
    let d = s.zdr;
    let (n_az, n_gates) = (d.grid.n_az, d.grid.n_gates);
    let half = |m: f64, spacing: f64| ((m / spacing).round() as usize).max(1);
    let clutter_tilt = s.elevation_deg <= CLUTTER_MAX_ELEVATION_DEG;
    let mut out = Grid::filled(n_az, n_gates, MISSING);
    // Per-gate layer is the same on every radial.
    let layers: Vec<Layer> = (0..n_gates).map(|g| layer_at(d.first_gate_m + g as f64 * d.gate_spacing_m, s.elevation_deg, ml)).collect();
    let mut zrow = vec![MISSING; n_gates];
    let mut rrow = vec![MISSING; n_gates];
    let mut prow = vec![MISSING; n_gates];
    for a in 0..n_az {
        for g in 0..n_gates {
            let r = d.first_gate_m + g as f64 * d.gate_spacing_m;
            zrow[g] = s.refl.at_range(a, n_az, r);
            rrow[g] = s.rho.at_range(a, n_az, r);
            prow[g] = s.phi.map_or(MISSING, |p| p.at_range(a, n_az, r));
        }
        let drow = d.grid.row(a);
        let hz = half(HALF_WINDOW_M.0, d.gate_spacing_m);
        let hp = half(HALF_WINDOW_M.1, d.gate_spacing_m);
        for g in 0..n_gates {
            if zrow[g] <= VALID_ABOVE || drow[g] <= VALID_ABOVE || rrow[g] <= VALID_ABOVE {
                continue;
            }
            let (Some((z, sd_z)), Some((zdr, _)), Some((rho, _))) =
                (window_stats(&zrow, g, hz), window_stats(drow, g, hz), window_stats(&rrow, g, hz))
            else {
                continue;
            };
            let r = d.first_gate_m + g as f64 * d.gate_spacing_m;
            let kdp = s.kdp.map_or(MISSING, |k| k.at_range(a, n_az, r));
            let gate = Gate {
                z,
                zdr,
                rho,
                lkdp: (kdp > VALID_ABOVE).then(|| lkdp(kdp as f64)),
                sd_z: Some(sd_z),
                sd_phi: phi_texture(&prow, g, hp),
            };
            out.set(a, g, (classify_gate(&gate, layers[g], clutter_tilt) + 1) as f32);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ml() -> MeltingLayer {
        MeltingLayer { bottom_m: 2500.0, top_m: 3000.0, source: "test".into(), n: 0 }
    }

    fn gate(z: f64, zdr: f64, rho: f64, kdp: Option<f64>, sd_z: f64, sd_phi: f64) -> Gate {
        Gate { z, zdr, rho, lkdp: kdp.map(lkdp), sd_z: Some(sd_z), sd_phi: Some(sd_phi) }
    }

    #[test]
    fn canonical_gates() {
        let cases = [
            ("RA", gate(30.0, 1.0, 0.99, Some(0.1), 1.0, 5.0), Layer::Below, false),
            ("HR", gate(50.0, 2.5, 0.98, Some(1.5), 1.0, 5.0), Layer::Below, false),
            ("RH", gate(60.0, 0.5, 0.93, Some(2.0), 2.0, 8.0), Layer::Below, false),
            ("BD", gate(35.0, 3.5, 0.98, Some(0.2), 1.0, 5.0), Layer::Below, false),
            ("BS", gate(15.0, 4.0, 0.6, None, 3.0, 30.0), Layer::Below, true),
            ("GC", gate(50.0, 0.0, 0.8, None, 8.0, 45.0), Layer::Below, true),
            ("WS", gate(38.0, 1.5, 0.93, Some(0.3), 1.0, 5.0), Layer::Within, false),
            ("DS", gate(25.0, 0.2, 0.995, Some(0.05), 1.0, 3.0), Layer::Above, false),
            ("CR", gate(10.0, 2.0, 0.99, Some(0.3), 1.0, 3.0), Layer::Above, false),
            ("GR", gate(45.0, 0.2, 0.99, None, 1.0, 3.0), Layer::Above, false),
            ("RH", gate(62.0, 0.3, 0.95, None, 2.0, 8.0), Layer::Above, false),
            ("UK", gate(70.0, 6.0, 0.3, None, 20.0, 5.0), Layer::Above, false),
        ];
        for (want, g, layer, clutter) in cases {
            let got = CLASSES[classify_gate(&g, layer, clutter)];
            assert_eq!(got, want, "{g:?} {layer:?}");
        }
        // Clutter-like gates on a high tilt are not called clutter.
        assert_ne!(CLASSES[classify_gate(&gate(50.0, 0.0, 0.8, None, 8.0, 45.0), Layer::Below, false)], "GC");
    }

    #[test]
    fn layers_from_the_beam() {
        let m = ml();
        assert_eq!(layer_at(20_000.0, 0.5, &m), Layer::Below); // ~0.2-0.4 km
        assert_eq!(layer_at(20_000.0, 7.5, &m), Layer::Within); // ~2.6 km
        assert_eq!(layer_at(40_000.0, 7.5, &m), Layer::Above); // ~5.3 km
    }

    #[test]
    fn climatology_is_plausible() {
        let jul = Utc::from_ymd_hms(2013, 7, 19, 0, 0, 0);
        let jan = Utc::from_ymd_hms(2013, 1, 17, 0, 0, 0);
        let (s35, w35) = (climatological_freezing_level_m(35.0, jul), climatological_freezing_level_m(35.0, jan));
        assert!((4400.0..5000.0).contains(&s35) && (1500.0..2300.0).contains(&w35), "{s35} {w35}");
        assert!(climatological_freezing_level_m(25.0, jan) > w35);
        assert!(climatological_freezing_level_m(64.0, jan) < 100.0);
    }

    /// Bright band between 2.5 and 3.0 km on tilts 4.5..9.5°, rain below, snow above.
    fn banded_sweeps() -> Vec<(f64, Grid, Grid, Grid)> {
        let (n_az, n_gates, first, spacing) = (360, 320, 2125.0, 250.0);
        [4.5, 6.0, 8.0, 9.5]
            .iter()
            .map(|&e| {
                let (mut z, mut d, mut c) =
                    (Grid::filled(n_az, n_gates, MISSING), Grid::filled(n_az, n_gates, MISSING), Grid::filled(n_az, n_gates, MISSING));
                for g in 0..n_gates {
                    let h = beam_height_m(first + g as f64 * spacing, e);
                    let (zz, dd, cc) = if h < 2500.0 {
                        (30.0, 0.8, 0.99)
                    } else if h < 3000.0 {
                        (40.0, 1.6, 0.93)
                    } else if h < 8000.0 {
                        (22.0, 0.3, 0.995)
                    } else {
                        continue;
                    };
                    for a in 0..n_az {
                        z.set(a, g, zz);
                        d.set(a, g, dd);
                        c.set(a, g, cc);
                    }
                }
                (e, z, d, c)
            })
            .collect()
    }

    fn inputs(s: &[(f64, Grid, Grid, Grid)]) -> Vec<SweepIn<'_>> {
        let m = |grid| Moment { grid, first_gate_m: 2125.0, gate_spacing_m: 250.0 };
        s.iter().map(|(e, z, d, c)| SweepIn { elevation_deg: *e, refl: m(z), zdr: m(d), rho: m(c), phi: None, kdp: None }).collect()
    }

    #[test]
    fn melting_layer_from_a_bright_band() {
        let s = banded_sweeps();
        let ml = detect_melting_layer(&inputs(&s)).expect("bright band");
        assert!((ml.bottom_m - 2500.0).abs() < 150.0 && (ml.top_m - 3000.0).abs() < 150.0, "{ml:?}");
        // Classify the 6° tilt: rain under the band, wet snow in it, dry snow over it.
        let hca = classify(&inputs(&s)[1], &ml);
        let class_at = |h: f64| {
            let g = (0..hca.n_gates).find(|&g| beam_height_m(2125.0 + g as f64 * 250.0, 6.0) >= h).unwrap();
            CLASSES[hca.at(0, g) as usize - 1]
        };
        assert_eq!(class_at(1000.0), "RA");
        assert_eq!(class_at(2750.0), "WS");
        assert_eq!(class_at(5000.0), "DS");
        // No band, no detection.
        let flat: Vec<_> = s.iter().map(|(e, z, d, _)| (*e, z.clone(), d.clone(), Grid::filled(360, 320, 0.99))).collect();
        assert!(detect_melting_layer(&inputs(&flat)).is_none());
    }
}
