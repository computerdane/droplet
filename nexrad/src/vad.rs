//! VAD wind profile and Bunkers storm motion from one volume.
//!
//! VAD (velocity-azimuth display): on a ring of constant slant range r in a sweep at
//! elevation e, a horizontally uniform wind (u east, v north) plus a vertical motion w shows
//! up as a sinusoid in azimuth phi (clockwise from north):
//!
//! ```text
//! Vr(phi) = a0 + cos(e) * (u * sin(phi) + v * cos(phi)),   a0 = w * sin(e)
//! ```
//!
//! so a least-squares fit of [1, sin, cos] per ring gives u and v at the beam height of that
//! ring. Rings are blocks of RING_GATES gates; each is fitted twice: first on the dealiased
//! velocity, then on the raw velocity unfolded against that first fit (value = model +
//! residual wrapped into +-Vn), dropping outliers. The second pass makes the fit immune to
//! dealiasing mistakes. Rings with poor azimuthal coverage or a large residual are rejected;
//! the rest are binned by height (median per HEIGHT_BIN_M layer).
//!
//! Bunkers et al. (2000) internal-dynamics method on the 0-6 km profile: the right mover is
//! 7.5 m/s to the right of the 0-6 km shear vector from the 0-6 km mean wind (left mover:
//! to the left). Storm-relative helicity for 0-1 and 0-3 km is computed against the right
//! mover.

use serde::{Deserialize, Serialize};

use crate::grid::{Grid, VALID_ABOVE};
use crate::round_to;

/// Gates per VAD ring (1 km at 250 m spacing).
pub const RING_GATES: usize = 4;
pub const MIN_RANGE_M: f64 = 5_000.0;
/// The wind must be roughly uniform across the ring.
pub const MAX_RANGE_M: f64 = 60_000.0;
pub const MAX_ELEVATION_DEG: f64 = 20.0;
/// Share of a ring's samples that must be valid.
pub const MIN_COVERAGE: f64 = 0.25;
/// Every 45-degree sector needs samples, or the sinusoid is unconstrained.
pub const SECTORS: usize = 8;
pub const MIN_PER_SECTOR: usize = 6;
pub const MAX_RMS_MS: f64 = 4.5;
pub const HEIGHT_BIN_M: f64 = 250.0;
pub const MAX_HEIGHT_M: f64 = 12_000.0;
pub const MIN_RINGS_PER_BIN: usize = 2;
/// 4/3-earth beam model, as in the shaders.
pub const EARTH_RADIUS_M: f64 = 6_371_000.0 * 4.0 / 3.0;
pub const BUNKERS_DEVIATION_MS: f64 = 7.5;

/// `{height_m, u_ms, v_ms, n}`: parallel lists, metres above the radar at bin centres,
/// m/s east/north, rings per bin.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct WindProfile {
    pub height_m: Vec<f64>,
    pub u_ms: Vec<f64>,
    pub v_ms: Vec<f64>,
    pub n: Vec<usize>,
}

/// Bunkers storm motion; vectors are `[u, v]` m/s.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StormMotion {
    pub method: String,
    pub right: [f64; 2],
    pub left: [f64; 2],
    pub mean_0_6km: [f64; 2],
    pub shear_0_6km: [f64; 2],
    pub srh_0_1km: f64,
    pub srh_0_3km: f64,
}

pub struct SweepIn<'a> {
    pub dvel: &'a Grid,
    /// Raw velocity on the same grid, if available.
    pub vel: Option<&'a Grid>,
    pub nyquist: f64,
    pub elevation_deg: f64,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
}

pub fn beam_height_m(slant_m: f64, elevation_deg: f64) -> f64 {
    let e = elevation_deg.to_radians();
    let r = EARTH_RADIUS_M;
    (slant_m * slant_m + r * r + 2.0 * slant_m * r * e.sin()).sqrt() - r
}

/// How far above the top or below the bottom of a profile it is still used, m.
pub const PROFILE_REACH_M: f64 = 500.0;

/// Wind (u, v) of the profile at `height_m`, linear between its levels; None beyond
/// PROFILE_REACH_M of its ends.
pub fn wind_at(p: &WindProfile, height_m: f64) -> Option<(f64, f64)> {
    let h = &p.height_m;
    if h.is_empty() || height_m < h[0] - PROFILE_REACH_M || height_m > h[h.len() - 1] + PROFILE_REACH_M {
        return None;
    }
    let k = h.partition_point(|&x| x <= height_m);
    if k == 0 {
        return Some((p.u_ms[0], p.v_ms[0]));
    }
    if k == h.len() {
        return Some((p.u_ms[k - 1], p.v_ms[k - 1]));
    }
    let f = (height_m - h[k - 1]) / (h[k] - h[k - 1]);
    Some((p.u_ms[k - 1] + f * (p.u_ms[k] - p.u_ms[k - 1]), p.v_ms[k - 1] + f * (p.v_ms[k] - p.v_ms[k - 1])))
}

/// The radial velocity the profile predicts on every gate of `sw` (row-major like its grid),
/// NaN where the beam is outside the profile: a dealiasing reference (see `dealias`).
pub fn radial_reference(p: &WindProfile, sw: &crate::dealias::SweepIn) -> Vec<f64> {
    let (n_az, n_g) = (sw.vel.n_az, sw.vel.n_gates);
    let cos_e = sw.elevation_deg.to_radians().cos();
    let wind: Vec<Option<(f64, f64)>> =
        (0..n_g).map(|g| wind_at(p, beam_height_m(sw.first_gate_m + g as f64 * sw.gate_spacing_m, sw.elevation_deg))).collect();
    let mut out = vec![f64::NAN; n_az * n_g];
    for a in 0..n_az {
        let az = ((a as f64 + 0.5) * 360.0 / n_az as f64).to_radians();
        let (s, c) = (az.sin() * cos_e, az.cos() * cos_e);
        for (g, w) in wind.iter().enumerate() {
            if let Some((u, v)) = w {
                out[a * n_g + g] = u * s + v * c;
            }
        }
    }
    out
}

/// One fitted ring: (height_m, u, v, rms).
pub type RingFit = (f64, f64, f64, f64);

/// VAD fits for one sweep, for every ring that passes the checks.
pub fn fit_rings(
    dvel: &Grid,
    vel: Option<&Grid>,
    nyquist: f64,
    elevation_deg: f64,
    first_gate_m: f64,
    gate_spacing_m: f64,
) -> Vec<RingFit> {
    if elevation_deg > MAX_ELEVATION_DEG {
        return Vec::new();
    }
    let (n_az, n_g) = (dvel.n_az, dvel.n_gates);
    let g0 = ((MIN_RANGE_M - first_gate_m) / gate_spacing_m).ceil().max(0.0) as usize;
    let g1 = (((MAX_RANGE_M - first_gate_m) / gate_spacing_m) as i64).max(0) as usize;
    let g1 = g1.min(n_g);
    if g1 <= g0 {
        return Vec::new();
    }
    let n_rings = (g1 - g0) / RING_GATES;
    if n_rings == 0 {
        return Vec::new();
    }
    let n_samples = n_az * RING_GATES;

    // Per sample j of a ring: azimuth bin j / RING_GATES, gate ring_start + j % RING_GATES.
    let az: Vec<f64> = (0..n_az).map(|a| ((a as f64 + 0.5) * 360.0 / n_az as f64).to_radians()).collect();
    let s: Vec<f64> = (0..n_samples).map(|j| az[j / RING_GATES].sin()).collect();
    let c: Vec<f64> = (0..n_samples).map(|j| az[j / RING_GATES].cos()).collect();
    let sector: Vec<usize> = (0..n_samples).map(|j| (j / RING_GATES) * SECTORS / n_az).collect();
    let cos_e = elevation_deg.to_radians().cos();

    let mut out = Vec::new();
    let mut y = vec![0f64; n_samples];
    let mut ok = vec![false; n_samples];
    let mut raw = vec![0f64; n_samples];
    for ring in 0..n_rings {
        let start = g0 + ring * RING_GATES;
        for j in 0..n_samples {
            y[j] = dvel.at(j / RING_GATES, start + j % RING_GATES) as f64;
            ok[j] = y[j] > VALID_ABOVE as f64;
        }
        let (mut coef, mut rms) = fit(&y, &ok, &s, &c);
        if let (Some(vel), true) = (vel, nyquist > 0.0) {
            for j in 0..n_samples {
                raw[j] = vel.at(j / RING_GATES, start + j % RING_GATES) as f64;
                ok[j] &= raw[j] > VALID_ABOVE as f64;
                let model = coef[0] + coef[1] * s[j] + coef[2] * c[j];
                let res = (raw[j] - model + nyquist).rem_euclid(2.0 * nyquist) - nyquist;
                y[j] = model + res;
                ok[j] &= res.abs() < 3.0 * rms.max(2.0);
            }
            (coef, rms) = fit(&y, &ok, &s, &c);
        }
        let n_valid = ok.iter().filter(|&&o| o).count();
        let mut per_sector = [0usize; SECTORS];
        for j in 0..n_samples {
            if ok[j] {
                per_sector[sector[j]] += 1;
            }
        }
        let good =
            n_valid as f64 >= MIN_COVERAGE * n_samples as f64 && per_sector.iter().all(|&k| k >= MIN_PER_SECTOR) && rms <= MAX_RMS_MS;
        if good {
            let slant = first_gate_m + (g0 as f64 + (ring as f64 + 0.5) * RING_GATES as f64 - 0.5) * gate_spacing_m;
            out.push((beam_height_m(slant, elevation_deg), coef[1] / cos_e, coef[2] / cos_e, rms));
        }
    }
    out
}

/// Least squares of y ~ a0 + a1 sin + a2 cos over the `ok` samples: coefficients and the
/// rms residual (infinite where singular).
fn fit(y: &[f64], ok: &[bool], s: &[f64], c: &[f64]) -> ([f64; 3], f64) {
    let mut ata = [[0f64; 3]; 3];
    let mut atb = [0f64; 3];
    let mut n = 0f64;
    for j in 0..y.len() {
        if !ok[j] {
            continue;
        }
        let b = [1.0, s[j], c[j]];
        n += 1.0;
        for i in 0..3 {
            atb[i] += b[i] * y[j];
            for k in i..3 {
                ata[i][k] += b[i] * b[k];
            }
        }
    }
    ata[1][0] = ata[0][1];
    ata[2][0] = ata[0][2];
    ata[2][1] = ata[1][2];
    let det = det3(&ata);
    if det.abs() <= 1e-6 * ata[0][0].max(1.0).powi(3) {
        return ([0.0; 3], f64::INFINITY);
    }
    let coef = solve3(ata, atb);
    let mut ss = 0f64;
    for j in 0..y.len() {
        if ok[j] {
            let r = y[j] - (coef[0] + coef[1] * s[j] + coef[2] * c[j]);
            ss += r * r;
        }
    }
    (coef, (ss / n.max(1.0)).sqrt())
}

fn det3(m: &[[f64; 3]; 3]) -> f64 {
    m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
}

/// Gaussian elimination with partial pivoting (the matrix is known to be non-singular).
fn solve3(mut a: [[f64; 3]; 3], mut b: [f64; 3]) -> [f64; 3] {
    for col in 0..3 {
        let p = (col..3).max_by(|&i, &j| a[i][col].abs().total_cmp(&a[j][col].abs())).unwrap();
        a.swap(col, p);
        b.swap(col, p);
        for row in col + 1..3 {
            let f = a[row][col] / a[col][col];
            let pivot = a[col];
            for (k, v) in a[row].iter_mut().enumerate().skip(col) {
                *v -= f * pivot[k];
            }
            b[row] -= f * b[col];
        }
    }
    let mut x = [0f64; 3];
    for row in (0..3).rev() {
        let mut v = b[row];
        for k in row + 1..3 {
            v -= a[row][k] * x[k];
        }
        x[row] = v / a[row][row];
    }
    x
}

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

/// Height-binned VAD profile from the sweeps of one volume, or None when no ring passed.
pub fn wind_profile(sweeps: &[SweepIn]) -> Option<WindProfile> {
    let mut fits: Vec<RingFit> = Vec::new();
    for sw in sweeps {
        fits.extend(fit_rings(sw.dvel, sw.vel, sw.nyquist, sw.elevation_deg, sw.first_gate_m, sw.gate_spacing_m));
    }
    if fits.is_empty() {
        return None;
    }
    let mut bins: std::collections::BTreeMap<i64, Vec<(f64, f64)>> = Default::default();
    for &(h, u, v, _) in &fits {
        let b = (h / HEIGHT_BIN_M).floor() as i64;
        if b >= 0 && h < MAX_HEIGHT_M {
            bins.entry(b).or_default().push((u, v));
        }
    }
    let mut out = WindProfile::default();
    for (k, uv) in bins {
        if uv.len() < MIN_RINGS_PER_BIN {
            continue;
        }
        let mut u: Vec<f64> = uv.iter().map(|p| p.0).collect();
        let mut v: Vec<f64> = uv.iter().map(|p| p.1).collect();
        out.height_m.push(round_to((k as f64 + 0.5) * HEIGHT_BIN_M, 1));
        out.u_ms.push(round_to(median(&mut u), 2));
        out.v_ms.push(round_to(median(&mut v), 2));
        out.n.push(uv.len());
    }
    (!out.height_m.is_empty()).then_some(out)
}

/// numpy.interp: linear between sorted `xp`, clamped to the end values outside.
fn interp(x: f64, xp: &[f64], fp: &[f64]) -> f64 {
    if x <= xp[0] {
        return fp[0];
    }
    if x >= xp[xp.len() - 1] {
        return fp[fp.len() - 1];
    }
    let i = xp.partition_point(|&p| p <= x); // xp[i-1] <= x < xp[i]
    let t = (x - xp[i - 1]) / (xp[i] - xp[i - 1]);
    fp[i - 1] + t * (fp[i] - fp[i - 1])
}

/// Bunkers right/left mover from a `wind_profile()`, or None when the profile does not
/// reach from near the ground (<= 1 km) to near 6 km (>= 5 km).
pub fn bunkers(profile: Option<&WindProfile>) -> Option<StormMotion> {
    let p = profile?;
    let h = &p.height_m;
    if h.is_empty() || h[0] > 1000.0 || h[h.len() - 1] < 5000.0 {
        return None;
    }
    let z: Vec<f64> = (0..).map(|i| i as f64 * HEIGHT_BIN_M).take_while(|&z| z <= 6000.0 + 1.0).collect();
    let uz: Vec<f64> = z.iter().map(|&zz| interp(zz, h, &p.u_ms)).collect();
    let vz: Vec<f64> = z.iter().map(|&zz| interp(zz, h, &p.v_ms)).collect();
    let mean_of = |v: &[f64], sel: &dyn Fn(f64) -> bool| {
        let picked: Vec<f64> = z.iter().zip(v).filter(|(zz, _)| sel(**zz)).map(|(_, x)| *x).collect();
        picked.iter().sum::<f64>() / picked.len() as f64
    };
    let mean = [mean_of(&uz, &|_| true), mean_of(&vz, &|_| true)];
    let low = |zz: f64| zz <= 500.0;
    let high = |zz: f64| zz >= 5500.0;
    let shear = [mean_of(&uz, &high) - mean_of(&uz, &low), mean_of(&vz, &high) - mean_of(&vz, &low)];
    let norm = shear[0].hypot(shear[1]);
    if norm < 1e-3 {
        return None;
    }
    let right = [shear[1] / norm * BUNKERS_DEVIATION_MS, -shear[0] / norm * BUNKERS_DEVIATION_MS];
    let rm = [mean[0] + right[0], mean[1] + right[1]];
    let lm = [mean[0] - right[0], mean[1] - right[1]];
    Some(StormMotion {
        method: "bunkers".into(),
        right: vec2(rm),
        left: vec2(lm),
        mean_0_6km: vec2(mean),
        shear_0_6km: vec2(shear),
        srh_0_1km: round_to(srh(&z, &uz, &vz, rm, 1000.0), 1),
        srh_0_3km: round_to(srh(&z, &uz, &vz, rm, 3000.0), 1),
    })
}

/// Storm-relative helicity (m^2/s^2) from the ground to `top`.
fn srh(z: &[f64], u: &[f64], v: &[f64], storm: [f64; 2], top: f64) -> f64 {
    let n = z.iter().filter(|&&zz| zz <= top).count();
    let su: Vec<f64> = u[..n].iter().map(|x| x - storm[0]).collect();
    let sv: Vec<f64> = v[..n].iter().map(|x| x - storm[1]).collect();
    (1..n).map(|i| su[i] * sv[i - 1] - su[i - 1] * sv[i]).sum()
}

fn vec2(a: [f64; 2]) -> [f64; 2] {
    [round_to(a[0], 2), round_to(a[1], 2)]
}

/// Recovers a veering, strengthening wind profile from synthetic aliased sweeps with noise,
/// missing gates and a blob of badly dealiased gates; returns (levels, max error m/s, srh_0_3km).
pub fn self_test() -> (usize, f64, f64) {
    use crate::synth::Rng;
    let mut rng = Rng::seed(1);
    let (n_az, n_g, vn) = (720usize, 1192usize, 26.0f64);
    // 10 m/s from the south at the ground veering to 30 m/s from the west at 6 km.
    let truth = |hgt: f64| {
        let f = (hgt / 6000.0).clamp(0.0, 1.5);
        let spd = 10.0 + 20.0 * f;
        let ang = (180.0 + 90.0 * f).to_radians();
        (-spd * ang.sin(), -spd * ang.cos())
    };
    let mut grids: Vec<(Grid, Grid, f64)> = Vec::new();
    for elev in [0.5f64, 0.9, 1.3, 1.8, 2.4, 3.1, 4.0, 5.1, 6.4, 8.0, 10.0, 12.5, 15.6, 19.5] {
        let cos_e = elev.to_radians().cos();
        let mut raw = Grid::filled(n_az, n_g, 0.0);
        let mut dvel = Grid::filled(n_az, n_g, 0.0);
        for a in 0..n_az {
            let az = ((a as f64 + 0.5) * 0.5).to_radians();
            for g in 0..n_g {
                let slant = 2125.0 + g as f64 * 250.0;
                let (u, v) = truth(beam_height_m(slant, elev));
                let t = cos_e * (u * az.sin() + v * az.cos()) + rng.normal() * 1.5;
                let mut d = t;
                if (100..140).contains(&a) && (200..260).contains(&g) {
                    d += 2.0 * vn; // a region the dealiaser got one fold wrong
                }
                let (r, d) = if rng.random() < 0.3 { (-1000.0, -1000.0) } else { ((t + vn).rem_euclid(2.0 * vn) - vn, d) };
                raw.set(a, g, r as f32);
                dvel.set(a, g, d as f32);
            }
        }
        grids.push((dvel, raw, elev));
    }
    let sweeps: Vec<SweepIn> = grids
        .iter()
        .map(|(d, r, e)| SweepIn { dvel: d, vel: Some(r), nyquist: vn, elevation_deg: *e, first_gate_m: 2125.0, gate_spacing_m: 250.0 })
        .collect();
    let prof = wind_profile(&sweeps).expect("a profile");
    let mut err_max = 0f64;
    for i in 0..prof.height_m.len() {
        let (tu, tv) = truth(prof.height_m[i]);
        err_max = err_max.max((prof.u_ms[i] - tu).hypot(prof.v_ms[i] - tv));
    }
    let bk = bunkers(Some(&prof)).expect("bunkers");
    (prof.height_m.len(), err_max, bk.srh_0_3km)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_profile_and_bunkers() {
        let (levels, err, srh3) = self_test();
        assert!(levels >= 10, "{levels}");
        assert!(err < 1.5, "{err}");
        assert!(srh3 > 0.0);
    }

    #[test]
    fn beam_height() {
        assert!((beam_height_m(0.0, 0.5)).abs() < 1e-6);
        // 100 km at 0.5 deg: ~1.46 km (0.87 km geometric + 0.59 km curvature).
        let h = beam_height_m(100_000.0, 0.5);
        assert!((h - 1461.0).abs() < 5.0, "{h}");
        assert!(beam_height_m(50_000.0, 10.0) > beam_height_m(50_000.0, 0.5));
    }

    fn uniform(n_az: usize, n_g: usize, elev: f64, u: f64, v: f64) -> Grid {
        let cos_e = elev.to_radians().cos();
        let mut g = Grid::filled(n_az, n_g, 0.0);
        for a in 0..n_az {
            let az = ((a as f64 + 0.5) * 360.0 / n_az as f64).to_radians();
            for gate in 0..n_g {
                g.set(a, gate, (cos_e * (u * az.sin() + v * az.cos())) as f32);
            }
        }
        g
    }

    #[test]
    fn fit_rings_recovers_uniform_wind() {
        let g = uniform(720, 400, 1.5, 12.0, -7.0);
        let fits = fit_rings(&g, None, 26.0, 1.5, 2125.0, 250.0);
        assert!(!fits.is_empty());
        for (h, u, v, rms) in fits {
            assert!(h > 0.0 && (u - 12.0).abs() < 1e-3 && (v + 7.0).abs() < 1e-3 && rms < 1e-3);
        }
        // The raw pass unfolds against the first fit.
        let mut raw = uniform(720, 400, 1.5, 12.0, -7.0);
        for x in raw.data.iter_mut() {
            *x = ((*x as f64 + 5.0).rem_euclid(10.0) - 5.0) as f32;
        }
        let fits = fit_rings(&g, Some(&raw), 5.0, 1.5, 2125.0, 250.0);
        assert!(fits.iter().all(|&(_, u, v, _)| (u - 12.0).abs() < 1e-3 && (v + 7.0).abs() < 1e-3));
    }

    #[test]
    fn fit_rings_rejects_steep_and_gappy_sweeps() {
        let g = uniform(720, 400, 25.0, 12.0, -7.0);
        assert!(fit_rings(&g, None, 26.0, 25.0, 2125.0, 250.0).is_empty());
        let mut gappy = uniform(720, 400, 1.5, 12.0, -7.0);
        for a in 0..90 {
            gappy.row_mut(a).fill(-1000.0); // one sector empty
        }
        assert!(fit_rings(&gappy, None, 26.0, 1.5, 2125.0, 250.0).is_empty());
        assert!(fit_rings(&Grid::filled(720, 10, 5.0), None, 26.0, 1.5, 2125.0, 250.0).is_empty()); // too short
    }

    #[test]
    fn wind_profile_none_without_data() {
        let g = Grid::filled(720, 400, -1000.0);
        let sw = SweepIn { dvel: &g, vel: None, nyquist: 26.0, elevation_deg: 0.5, first_gate_m: 2125.0, gate_spacing_m: 250.0 };
        assert!(wind_profile(&[sw]).is_none());
        assert!(wind_profile(&[]).is_none());
        assert!(bunkers(None).is_none());
    }

    #[test]
    fn bunkers_straight_hodograph() {
        // Wind from the south increasing with height: shear points north, RM is 7.5 m/s east of the mean.
        let h: Vec<f64> = (0..28).map(|i| 125.0 + i as f64 * 250.0).collect();
        let v: Vec<f64> = h.iter().map(|z| 5.0 + z / 6000.0 * 20.0).collect();
        let p = WindProfile { u_ms: vec![0.0; h.len()], v_ms: v, n: vec![2; h.len()], height_m: h };
        let bk = bunkers(Some(&p)).unwrap();
        assert!((bk.right[0] - 7.5).abs() < 1e-6 && (bk.left[0] + 7.5).abs() < 1e-6);
        assert!((bk.right[1] - bk.mean_0_6km[1]).abs() < 1e-6);
        assert!(bk.shear_0_6km[1] > 0.0 && bk.shear_0_6km[0].abs() < 1e-9);
        assert!(bk.srh_0_1km > 0.0 && bk.srh_0_3km > bk.srh_0_1km);
        assert_eq!(interp(300.0, &[0.0, 1000.0], &[0.0, 10.0]), 3.0);
        assert_eq!(interp(-5.0, &[0.0, 1000.0], &[1.0, 10.0]), 1.0);
        assert_eq!(interp(5000.0, &[0.0, 1000.0], &[1.0, 10.0]), 10.0);
    }

    #[test]
    fn bunkers_needs_deep_profile() {
        let h: Vec<f64> = (0..8).map(|i| 125.0 + i as f64 * 250.0).collect(); // tops out ~2 km
        let p = WindProfile { u_ms: vec![1.0; 8], v_ms: vec![2.0; 8], n: vec![2; 8], height_m: h };
        assert!(bunkers(Some(&p)).is_none());
        let h: Vec<f64> = (0..28).map(|i| 1125.0 + i as f64 * 250.0).collect(); // starts too high
        let p = WindProfile { u_ms: vec![1.0; 28], v_ms: vec![2.0; 28], n: vec![2; 28], height_m: h };
        assert!(bunkers(Some(&p)).is_none());
        let h: Vec<f64> = (0..28).map(|i| 125.0 + i as f64 * 250.0).collect(); // no shear
        let p = WindProfile { u_ms: vec![1.0; 28], v_ms: vec![2.0; 28], n: vec![2; 28], height_m: h };
        assert!(bunkers(Some(&p)).is_none());
    }
}
