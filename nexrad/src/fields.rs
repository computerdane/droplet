//! Per-gate fields derived from the moments of one sweep, written next to them like DVEL:
//!
//! - `AZSHR` azimuthal shear of the dealiased radial velocity, in 10⁻³ s⁻¹ (positive =
//!   cyclonic in the northern hemisphere: velocity increasing clockwise). Linear least squares
//!   derivative (LLSD) of DVEL against arc length over `AZSHR_HALF_WIDTH_M` either side of
//!   the gate and one gate either side in range, as MRMS computes it; left out where DVEL
//!   scatters by more than `AZSHR_MAX_RESIDUAL_MS` about the fit (fold errors, clutter).
//! - `KDP` specific differential phase (°/km): half the range derivative of PHI, a least
//!   squares slope over `KDP_HALF_WINDOW_M` either side of the gate (shorter in heavy rain) on
//!   PHI that is first unwrapped and median filtered along the radial, using only gates with
//!   RHO ≥ `KDP_MIN_RHO` and REF ≥ `KDP_MIN_DBZ`, and only where PHI stays within
//!   `KDP_MAX_RESIDUAL_DEG` of the fit (non-meteorological echo has a noisy phase).

use crate::grid::{Grid, VALID_ABOVE};
use crate::level2::MISSING;

pub const AZSHR_HALF_WIDTH_M: f64 = 750.0;
pub const AZSHR_MAX_RADIALS: usize = 10;
/// Ranges closer than this get no shear (a radial is only metres wide there).
pub const AZSHR_MIN_RANGE_M: f64 = 2000.0;
/// No shear where DVEL scatters more than this about the fitted line (m/s).
pub const AZSHR_MAX_RESIDUAL_MS: f64 = 6.0;
/// Half the fitting window: (REF >= KDP_HEAVY_DBZ, lighter echo), as the NEXRAD KDP uses
/// 9 and 25 gates.
pub const KDP_HALF_WINDOW_M: (f64, f64) = (1000.0, 3000.0);
pub const KDP_HEAVY_DBZ: f32 = 40.0;
/// No KDP in echo weaker than this (its phase is mostly noise).
pub const KDP_MIN_DBZ: f32 = 20.0;
pub const KDP_MIN_RHO: f32 = 0.9;
/// No KDP where PHI scatters more than this about the fitted line (non-meteorological echo).
pub const KDP_MAX_RESIDUAL_DEG: f64 = 6.0;
pub const KDP_RANGE: (f32, f32) = (-2.0, 10.0);

/// Azimuthal shear of `vel` (m/s, any sentinels) on a sweep of `n_az` rows covering 360°.
pub fn azimuthal_shear(vel: &Grid, first_gate_m: f64, gate_spacing_m: f64) -> Grid {
    let (n_az, n_gates) = (vel.n_az, vel.n_gates);
    let step = std::f64::consts::TAU / n_az as f64;
    let mut out = Grid::filled(n_az, n_gates, MISSING);
    for g in 0..n_gates {
        let r = first_gate_m + g as f64 * gate_spacing_m;
        if r < AZSHR_MIN_RANGE_M {
            continue;
        }
        let ds = r * step; // arc length between neighbouring radials
        let n = ((AZSHR_HALF_WIDTH_M / ds).round() as usize).clamp(1, AZSHR_MAX_RADIALS);
        let g0 = g.saturating_sub(1);
        let g1 = (g + 1).min(n_gates - 1);
        for a in 0..n_az {
            if vel.at(a, g) <= VALID_ABOVE {
                continue;
            }
            let (mut sx, mut sv, mut sxx, mut sxv, mut svv, mut count) = (0.0, 0.0, 0.0, 0.0, 0.0, 0usize);
            let (mut left, mut right) = (false, false);
            for k in -(n as i64)..=n as i64 {
                let row = (a as i64 + k).rem_euclid(n_az as i64) as usize;
                let x = k as f64 * ds;
                for gg in g0..=g1 {
                    let v = vel.at(row, gg);
                    if v > VALID_ABOVE {
                        let v = v as f64;
                        (sx, sv, sxx, sxv, svv) = (sx + x, sv + v, sxx + x * x, sxv + x * v, svv + v * v);
                        count += 1;
                        left |= k < 0;
                        right |= k > 0;
                    }
                }
            }
            let total = (2 * n + 1) * (g1 - g0 + 1);
            if !(left && right) || count * 2 < total {
                continue;
            }
            let c = count as f64;
            let (var_x, cov) = (sxx - sx * sx / c, sxv - sx * sv / c);
            if var_x <= 0.0 {
                continue;
            }
            let slope = cov / var_x;
            // A fold error or clutter inside the window leaves a large misfit: no shear there.
            let residual = ((svv - sv * sv / c - slope * cov).max(0.0) / c).sqrt();
            if residual <= AZSHR_MAX_RESIDUAL_MS {
                out.set(a, g, (slope * 1000.0) as f32);
            }
        }
    }
    out
}

/// KDP from `phi` (degrees) with `rho` and, when given, `refl` of the same sweep (all on the
/// same gate spacing from the same first gate; gates beyond a grid's reach count as missing).
pub fn kdp(phi: &Grid, rho: &Grid, refl: Option<&Grid>, gate_spacing_m: f64) -> Grid {
    let (n_az, n_gates) = (phi.n_az, phi.n_gates);
    let gates = |m: f64| ((m / gate_spacing_m).round() as usize).max(2);
    let (half_heavy, half_light) = (gates(KDP_HALF_WINDOW_M.0), gates(KDP_HALF_WINDOW_M.1));
    let km_per_gate = gate_spacing_m / 1000.0;
    let row_of = |g: &Grid, a: usize| a * g.n_az / n_az;
    let mut out = Grid::filled(n_az, n_gates, MISSING);
    let mut unwrapped: Vec<f64> = vec![f64::NAN; n_gates];
    let mut clean: Vec<f64> = vec![f64::NAN; n_gates];
    let mut heavy: Vec<bool> = vec![false; n_gates];
    for a in 0..n_az {
        let rho_row = rho.row(row_of(rho, a));
        let ref_row = refl.map(|r| r.row(row_of(r, a)));
        // Unwrap along the radial over the gates we trust (a true fold jumps by ~360°, noise
        // by far less), then a 5-gate median.
        let mut prev: Option<f64> = None;
        for g in 0..n_gates {
            unwrapped[g] = f64::NAN;
            let (p, r) = (phi.at(a, g), rho_row.get(g).copied().unwrap_or(MISSING));
            let z = ref_row.map_or(KDP_HEAVY_DBZ, |row| row.get(g).copied().unwrap_or(MISSING));
            heavy[g] = z >= KDP_HEAVY_DBZ;
            if p <= VALID_ABOVE || r < KDP_MIN_RHO || z < KDP_MIN_DBZ {
                continue;
            }
            let mut p = p as f64;
            if let Some(q) = prev {
                while q - p > 270.0 {
                    p += 360.0;
                }
                while p - q > 270.0 {
                    p -= 360.0;
                }
            }
            unwrapped[g] = p;
            prev = Some(p);
        }
        for g in 0..n_gates {
            clean[g] = f64::NAN;
            if unwrapped[g].is_nan() {
                continue;
            }
            let mut w = [0.0f64; 5];
            let mut n = 0;
            for &v in &unwrapped[g.saturating_sub(2)..(g + 3).min(n_gates)] {
                if !v.is_nan() {
                    w[n] = v;
                    n += 1;
                }
            }
            w[..n].sort_by(f64::total_cmp);
            clean[g] = w[n / 2];
        }
        for g in 0..n_gates {
            if clean[g].is_nan() {
                continue;
            }
            let half = if heavy[g] { half_heavy } else { half_light };
            let (lo, hi) = (g.saturating_sub(half), (g + half).min(n_gates - 1));
            let (mut sx, mut sp, mut sxx, mut sxp, mut spp, mut count) = (0.0, 0.0, 0.0, 0.0, 0.0, 0usize);
            for (k, &p) in clean.iter().enumerate().take(hi + 1).skip(lo) {
                if !p.is_nan() {
                    let x = (k as f64 - g as f64) * km_per_gate;
                    (sx, sp, sxx, sxp, spp) = (sx + x, sp + p, sxx + x * x, sxp + x * p, spp + p * p);
                    count += 1;
                }
            }
            if count * 3 < (hi - lo + 1) * 2 {
                continue;
            }
            let c = count as f64;
            let (var_x, cov) = (sxx - sx * sx / c, sxp - sx * sp / c);
            if var_x <= 0.0 {
                continue;
            }
            let slope = cov / var_x;
            let residual = ((spp - sp * sp / c - slope * cov).max(0.0) / c).sqrt();
            if residual <= KDP_MAX_RESIDUAL_DEG {
                out.set(a, g, ((0.5 * slope) as f32).clamp(KDP_RANGE.0, KDP_RANGE.1));
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shear_of_solid_body_rotation() {
        // A vortex centred 30 km north, rotating counter-clockwise (cyclonic) at 0.01 rad/s:
        // the radial velocity changes by 0.01 m/s per metre across it, so AZSHR = 10.
        let (n_az, n_gates, first, spacing) = (720, 200, 125.0, 250.0);
        let omega = 0.01;
        let mut vel = Grid::filled(n_az, n_gates, MISSING);
        for a in 0..n_az {
            let az = ((a as f64 + 0.5) * 0.5).to_radians();
            for g in 0..n_gates {
                let r = first + g as f64 * spacing;
                let (x, y) = (r * az.sin(), r * az.cos() - 30_000.0);
                if x.hypot(y) < 3000.0 {
                    let (u, v) = (-omega * y, omega * x);
                    vel.set(a, g, (u * az.sin() + v * az.cos()) as f32);
                }
            }
        }
        let s = azimuthal_shear(&vel, first, spacing);
        let g = ((30_000.0 - first) / spacing) as usize;
        for a in [0usize, 1, 719] {
            assert!((s.at(a, g) - 10.0).abs() < 0.3, "row {a}: {}", s.at(a, g));
        }
        // Outside the vortex there is no data, so no shear.
        assert_eq!(s.at(360, g), MISSING);
    }

    #[test]
    fn kdp_of_a_phase_ramp() {
        // PHI rising 3 °/km from 20 km to 40 km (KDP 1.5), wrapping past 360, with a spike and
        // a gate of low RHO that must not matter.
        let (n_az, n_gates, spacing) = (2, 240, 250.0);
        let mut phi = Grid::filled(n_az, n_gates, MISSING);
        let mut rho = Grid::filled(n_az, n_gates, 0.99);
        for g in 0..n_gates {
            let km = g as f64 * spacing / 1000.0;
            let p = 300.0 + 3.0 * (km.clamp(20.0, 40.0) - 20.0);
            phi.set(0, g, (p % 360.0) as f32);
            phi.set(1, g, p as f32);
        }
        phi.set(0, 120, 10.0); // spike
        rho.set(0, 124, 0.5);
        phi.set(0, 124, 200.0);
        let k = kdp(&phi, &rho, None, spacing);
        for row in 0..2 {
            assert!((k.at(row, 108) - 1.5).abs() < 0.05, "ramp {row}: {}", k.at(row, 108));
            assert!((k.at(row, 120) - 1.5).abs() < 0.25, "ramp by the spike {row}: {}", k.at(row, 120));
            assert!(k.at(row, 40).abs() < 0.05, "flat {row}: {}", k.at(row, 40));
        }
        assert_eq!(k.at(0, 124), MISSING, "low RHO gate");
    }
}
