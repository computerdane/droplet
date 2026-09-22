//! Storm cells of one volume, SCIT-style, from the column products (`products`): regions of
//! composite reflectivity at or above `THRESHOLDS[0]`, split into their cores at the higher
//! thresholds while a region holds two or more cores of at least `MIN_AREA_KM2`. Each cell
//! reports its reflectivity-weighted centroid, area, maximum CREF / VIL / echo top, the
//! strongest low-level rotation within `SEARCH_KM`, and a tornado debris signature flag: gates
//! of the lowest dual-pol tilt within `SEARCH_KM` with high REF, low RHO and low ZDR where the
//! low-level rotation is strong. Tracking cells over time is left to the viewer.

use serde::{Deserialize, Serialize};

use crate::grid::{Grid, VALID_ABOVE};

pub const THRESHOLDS: [f32; 3] = [40.0, 50.0, 60.0];
pub const MIN_AREA_KM2: f64 = 8.0;
/// Radius around a centroid searched for rotation and debris.
pub const SEARCH_KM: f64 = 8.0;
/// Debris: a cell whose rotation reaches TDS_MIN_ROT, with at least TDS_MIN_GATES gates of REF
/// at least this, RHO and ZDR at most these, near the rotation maximum.
pub const TDS_MIN_DBZ: f32 = 40.0;
pub const TDS_MAX_RHO: f32 = 0.80;
pub const TDS_MAX_ZDR: f32 = 0.5;
pub const TDS_MIN_ROT: f32 = 10.0;
pub const TDS_MIN_GATES: usize = 6;
/// Debris is looked for this close to the rotation maximum.
pub const TDS_RADIUS_KM: f64 = 3.0;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Cell {
    /// Centroid, km east and north of the radar (ground distance).
    pub x_km: f64,
    pub y_km: f64,
    pub area_km2: f64,
    pub max_dbz: f64,
    /// Largest VIL (kg/m²) and echo top (km above the radar) in the cell, 0 if none.
    pub vil: f64,
    pub top_km: f64,
    /// Strongest low-level rotation (ROT, 10⁻³ s⁻¹) within SEARCH_KM, 0 if none.
    pub rot: f64,
    /// Tornado debris signature near the rotation.
    pub tds: bool,
}

/// The product grids (same geometry: `N_AZIMUTH_BINS` rows over ground distance).
pub struct ProductGrids<'a> {
    pub cref: &'a Grid,
    pub echo_top: &'a Grid,
    pub vil: &'a Grid,
    pub rot: &'a Grid,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
}

/// The lowest tilt with REF, RHO and ZDR on one sweep, for the debris check.
pub struct DualPol<'a> {
    pub refl: &'a Grid,
    pub rho: &'a Grid,
    pub zdr: &'a Grid,
    pub elevation_deg: f64,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
}

impl ProductGrids<'_> {
    fn ground_km(&self, g: usize) -> f64 {
        (self.first_gate_m + g as f64 * self.gate_spacing_m) / 1000.0
    }

    fn xy(&self, idx: usize) -> (f64, f64) {
        let n = self.cref.n_gates;
        let az = ((idx / n) as f64 + 0.5) * std::f64::consts::TAU / self.cref.n_az as f64;
        let s = self.ground_km(idx % n).max(0.0);
        (s * az.sin(), s * az.cos())
    }

    fn area_km2(&self, idx: usize) -> f64 {
        let s = self.ground_km(idx % self.cref.n_gates).max(0.0);
        s * std::f64::consts::TAU / self.cref.n_az as f64 * self.gate_spacing_m / 1000.0
    }

    /// Flat indices of the gates within `km` of the point (x, y), by scanning the polar box
    /// around it.
    fn near(&self, x: f64, y: f64, km: f64) -> Vec<usize> {
        let (n_az, n) = (self.cref.n_az, self.cref.n_gates);
        let s = x.hypot(y);
        let az = x.atan2(y).rem_euclid(std::f64::consts::TAU);
        let spacing = self.gate_spacing_m / 1000.0;
        let g0 = (((s - km) * 1000.0 - self.first_gate_m) / self.gate_spacing_m).floor().max(0.0) as usize;
        let g1 = ((((s + km) * 1000.0 - self.first_gate_m) / self.gate_spacing_m).ceil().max(0.0) as usize).min(n.saturating_sub(1));
        let half = if s <= km { std::f64::consts::PI } else { (km / s).asin() };
        let step = std::f64::consts::TAU / n_az as f64;
        let rows = ((half / step).ceil() as i64).min(n_az as i64 / 2);
        let centre = (az / step) as i64;
        let mut out = Vec::new();
        for dr in -rows..=rows {
            let row = (centre + dr).rem_euclid(n_az as i64) as usize;
            for g in g0..=g1 {
                let idx = row * n + g;
                let (px, py) = self.xy(idx);
                if (px - x).hypot(py - y) <= km && spacing > 0.0 {
                    out.push(idx);
                }
            }
        }
        out.sort_unstable();
        out.dedup();
        out
    }
}

/// Connected regions (4-neighbours, wrapping in azimuth) of the gates in `within` (or the
/// whole grid) whose CREF is at least `thr`.
fn components(cref: &Grid, thr: f32, within: Option<&[usize]>) -> Vec<Vec<usize>> {
    let (n_az, n) = (cref.n_az, cref.n_gates);
    let mut allowed = vec![within.is_none(); cref.data.len()];
    if let Some(w) = within {
        for &i in w {
            allowed[i] = true;
        }
    }
    let on = |i: usize| allowed[i] && cref.data[i] > VALID_ABOVE && cref.data[i] >= thr;
    let mut seen = vec![false; cref.data.len()];
    let mut out = Vec::new();
    let starts: Vec<usize> = match within {
        Some(w) => w.to_vec(),
        None => (0..cref.data.len()).collect(),
    };
    for start in starts {
        if seen[start] || !on(start) {
            continue;
        }
        let mut region = Vec::new();
        let mut stack = vec![start];
        seen[start] = true;
        while let Some(i) = stack.pop() {
            region.push(i);
            let (row, g) = (i / n, i % n);
            let mut next = vec![((row + 1) % n_az) * n + g, ((row + n_az - 1) % n_az) * n + g];
            if g > 0 {
                next.push(i - 1);
            }
            if g + 1 < n {
                next.push(i + 1);
            }
            for j in next {
                if !seen[j] && on(j) {
                    seen[j] = true;
                    stack.push(j);
                }
            }
        }
        out.push(region);
    }
    out
}

/// Cells of one volume, strongest first.
pub fn find_cells(p: &ProductGrids, dual_pol: Option<&DualPol>) -> Vec<Cell> {
    let area = |gates: &[usize]| gates.iter().map(|&i| p.area_km2(i)).sum::<f64>();
    let mut regions: Vec<Vec<usize>> = Vec::new();
    let mut todo: Vec<(Vec<usize>, usize)> =
        components(p.cref, THRESHOLDS[0], None).into_iter().filter(|r| area(r) >= MIN_AREA_KM2).map(|r| (r, 0)).collect();
    while let Some((region, level)) = todo.pop() {
        if level + 1 < THRESHOLDS.len() {
            let cores: Vec<Vec<usize>> =
                components(p.cref, THRESHOLDS[level + 1], Some(&region)).into_iter().filter(|r| area(r) >= MIN_AREA_KM2).collect();
            if cores.len() >= 2 {
                todo.extend(cores.into_iter().map(|c| (c, level + 1)));
                continue;
            }
        }
        regions.push(region);
    }
    let max_of = |g: &Grid, gates: &[usize]| gates.iter().map(|&i| g.data[i]).filter(|&v| v > VALID_ABOVE).fold(0.0f32, f32::max) as f64;
    let mut cells: Vec<Cell> = regions
        .iter()
        .map(|gates| {
            let (mut wx, mut wy, mut w) = (0.0, 0.0, 0.0);
            for &i in gates {
                let z = 10f64.powf(p.cref.data[i] as f64 / 10.0);
                let (x, y) = p.xy(i);
                (wx, wy, w) = (wx + z * x, wy + z * y, w + z);
            }
            let (x, y) = (wx / w, wy / w);
            let around = p.near(x, y, SEARCH_KM);
            let rot = max_of(p.rot, &around);
            let peak =
                around.iter().copied().filter(|&i| p.rot.data[i] > VALID_ABOVE).max_by(|&i, &j| p.rot.data[i].total_cmp(&p.rot.data[j]));
            let tds = rot >= TDS_MIN_ROT as f64
                && peak.zip(dual_pol).is_some_and(|(i, d)| {
                    let (px, py) = p.xy(i);
                    debris(d, px, py)
                });
            Cell {
                x_km: crate::round_to(x, 2),
                y_km: crate::round_to(y, 2),
                area_km2: crate::round_to(area(gates), 1),
                max_dbz: crate::round_to(gates.iter().map(|&i| p.cref.data[i]).fold(f32::MIN, f32::max) as f64, 1),
                vil: crate::round_to(max_of(p.vil, gates), 1),
                top_km: crate::round_to(max_of(p.echo_top, gates), 2),
                rot: crate::round_to(rot, 1),
                tds,
            }
        })
        .collect();
    cells.sort_by(|a, b| b.max_dbz.total_cmp(&a.max_dbz).then(b.area_km2.total_cmp(&a.area_km2)));
    cells
}

/// At least TDS_MIN_GATES gates of the dual-pol tilt within TDS_RADIUS_KM of (x, y) (the
/// rotation maximum) that look like lofted debris: high REF, low RHO, low ZDR. Only the
/// polar box around the point is scanned.
fn debris(d: &DualPol, x: f64, y: f64) -> bool {
    let cos_e = d.elevation_deg.to_radians().cos();
    let (n_az, n) = (d.refl.n_az, d.refl.n_gates.min(d.rho.n_gates).min(d.zdr.n_gates));
    let s = x.hypot(y);
    let step = std::f64::consts::TAU / n_az as f64;
    let half = if s <= TDS_RADIUS_KM { std::f64::consts::PI } else { (TDS_RADIUS_KM / s).asin() };
    let rows = ((half / step).ceil() as i64).min(n_az as i64 / 2);
    let centre = (x.atan2(y).rem_euclid(std::f64::consts::TAU) / step) as i64;
    let gate = |km: f64| ((km / cos_e * 1000.0 - d.first_gate_m) / d.gate_spacing_m).max(0.0);
    let (g0, g1) = (gate(s - TDS_RADIUS_KM).floor() as usize, (gate(s + TDS_RADIUS_KM).ceil() as usize).min(n));
    let mut hits = 0;
    for dr in -rows..=rows {
        let row = (centre + dr).rem_euclid(n_az as i64) as usize;
        let az = (row as f64 + 0.5) * step;
        for g in g0..g1 {
            let r = (d.first_gate_m + g as f64 * d.gate_spacing_m) / 1000.0 * cos_e;
            if (r * az.sin() - x).hypot(r * az.cos() - y) > TDS_RADIUS_KM {
                continue;
            }
            let (z, rho, zdr) = (d.refl.at(row, g), d.rho.at(row, g), d.zdr.at(row, g));
            if z >= TDS_MIN_DBZ && rho > VALID_ABOVE && rho <= TDS_MAX_RHO && zdr > VALID_ABOVE && zdr <= TDS_MAX_ZDR {
                hits += 1;
            }
        }
    }
    hits >= TDS_MIN_GATES
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::level2::MISSING;

    /// Product grids (720 x 400 gates of 250 m) with Gaussian cells at (x, y, peak dBZ, radius).
    fn scene(blobs: &[(f64, f64, f32, f64)]) -> (Grid, Grid, Grid, Grid) {
        let (n_az, n) = (720, 400);
        let mut cref = Grid::filled(n_az, n, MISSING);
        for row in 0..n_az {
            let az = (row as f64 + 0.5) * std::f64::consts::TAU / n_az as f64;
            for g in 0..n {
                let s = (125.0 + g as f64 * 250.0) / 1000.0;
                let (x, y) = (s * az.sin(), s * az.cos());
                let v =
                    blobs.iter().map(|&(bx, by, peak, r)| peak * (-((x - bx).hypot(y - by) / r).powi(2)).exp() as f32).fold(0.0, f32::max);
                if v >= 5.0 {
                    cref.set(row, g, v);
                }
            }
        }
        let mut vil = cref.clone();
        vil.data.iter_mut().for_each(|v| *v = if *v > 50.0 { *v - 20.0 } else { MISSING });
        let et = Grid::filled(n_az, n, 9.0);
        let rot = Grid::filled(n_az, n, MISSING);
        (cref, et, vil, rot)
    }

    #[test]
    fn cells_split_into_cores() {
        // Two 65 dBZ cores 8 km apart share one 40 dBZ region; a third, weak cell stands
        // alone; a speck too small to count.
        let (cref, et, vil, rot) =
            scene(&[(20.0, 30.0, 65.0, 6.0), (28.0, 30.0, 65.0, 6.0), (-40.0, -10.0, 48.0, 5.0), (0.0, -60.0, 45.0, 0.6)]);
        let p = ProductGrids { cref: &cref, echo_top: &et, vil: &vil, rot: &rot, first_gate_m: 125.0, gate_spacing_m: 250.0 };
        let cells = find_cells(&p, None);
        assert_eq!(cells.len(), 3, "{cells:?}");
        let mut xs: Vec<(f64, f64)> = cells.iter().map(|c| (c.x_km, c.y_km)).collect();
        xs.sort_by(|a, b| a.0.total_cmp(&b.0));
        for ((x, y), (wx, wy)) in xs.iter().zip([(-40.0, -10.0), (20.0, 30.0), (28.0, 30.0)]) {
            assert!((x - wx).abs() < 1.0 && (y - wy).abs() < 1.0, "centroid ({x}, {y}) vs ({wx}, {wy})");
        }
        let strong = &cells[0];
        assert!((strong.max_dbz - 65.0).abs() < 0.5 && strong.vil > 40.0 && strong.top_km == 9.0 && strong.rot == 0.0);
        assert!(cells[2].max_dbz < 50.0 && cells[2].vil == 0.0);
    }
}
