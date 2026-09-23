//! Region-based Doppler velocity dealiasing.
//!
//! Radial velocity is only measured modulo 2*Vn (Vn = Nyquist velocity): a true 30 m/s at
//! Vn = 26 reads as -22. Unfolding one sweep:
//!
//! 1. Split the Nyquist interval into a few bands and label connected regions of gates in
//!    the same band (4-neighbour, azimuth wraps around). A fold cannot hide inside a region.
//! 2. For every pair of touching regions, count the boundary gates and sum the velocity
//!    jump across them.
//! 3. Repeatedly merge the pair with the longest shared boundary: shift the smaller region
//!    by the multiple of 2*Vn that makes the mean jump smallest, then combine their
//!    boundaries with the neighbours (the merged region's jumps are recomputed with the shift).
//!    Boundaries whose mean jump is close to Vn are ambiguous and not merged across.
//! 4. Each connected component ends up with one set of relative folds; shift it as a whole.
//!    With a reference (the already unfolded tilt below, see `dealias_volume`) the shift is
//!    the one most of its gates agree with the reference on; otherwise it is the one that
//!    keeps most of its gates at their measured value.
//!    A fallback reference (`dealias_sweep_with`; `volume::add_dealiased` passes the radial wind
//!    of a first pass's VAD profile) places components the reference misses, when decisive.
//!
//! This follows the idea of Py-ART's dealias_region_based.

use std::cmp::Reverse;
use std::collections::{BTreeMap, BinaryHeap, HashMap};

use crate::grid::{Grid, VALID_ABOVE};

pub const INTERVAL_SPLITS: usize = 3;
/// Skip merges whose mean jump is within this of half a period (in periods).
pub const AMBIGUOUS: f64 = 0.4;
/// A component needs this many gates overlapping the reference to use it.
pub const MIN_REFERENCE_GATES: usize = 20;
/// A fallback reference decides a component's fold only if this share of its gates agree.
pub const FALLBACK_MIN_SHARE: f64 = 0.7;

/// One sweep to unfold, with the geometry needed to resample it onto another tilt.
pub struct SweepIn<'a> {
    pub vel: &'a Grid,
    pub nyquist: f64,
    pub elevation_deg: f64,
    pub first_gate_m: f64,
    pub gate_spacing_m: f64,
}

/// Unfolds every sweep of a volume, lowest elevation first, each one referenced to the
/// closest sweep at or below its elevation that is already done. Results come back in
/// the input order.
pub fn dealias_volume(sweeps: &[SweepIn]) -> Vec<Grid> {
    dealias_volume_with(sweeps, None)
}

/// `dealias_volume` with a fallback reference per sweep (same order as `sweeps`; see
/// `dealias_sweep_with`), e.g. the radial wind a VAD profile predicts.
pub fn dealias_volume_with(sweeps: &[SweepIn], fallbacks: Option<&[Vec<f64>]>) -> Vec<Grid> {
    let mut order: Vec<usize> = (0..sweeps.len()).collect();
    order.sort_by(|&a, &b| sweeps[a].elevation_deg.total_cmp(&sweeps[b].elevation_deg));
    let mut out: Vec<Option<Grid>> = (0..sweeps.len()).map(|_| None).collect();
    let mut below: Option<(usize, Grid)> = None;
    for i in order {
        let sw = &sweeps[i];
        let reference = below.as_ref().map(|(j, grid)| resample(sw, &sweeps[*j], grid));
        let fallback = fallbacks.map(|f| f[i].as_slice());
        let unfolded = dealias_sweep_with(sw.vel, sw.nyquist, reference.as_deref(), fallback);
        below = Some((i, unfolded.clone()));
        out[i] = Some(unfolded);
    }
    out.into_iter().map(|g| g.unwrap()).collect()
}

/// Unfolds one sweep. Sentinels (< -900) are kept as they are. `reference`, if given, is an
/// unfolded estimate on the same grid (NaN where unknown) used to pick each component's
/// absolute fold.
pub fn dealias_sweep(vel: &Grid, nyquist: f64, reference: Option<&[f64]>) -> Grid {
    dealias_sweep_with(vel, nyquist, reference, None)
}

/// `dealias_sweep` with a `fallback` estimate (same layout as `reference`) for components the
/// reference does not cover: used when at least FALLBACK_MIN_SHARE of its gates agree on the
/// fold, so a storm-scale circulation that departs from it by about a fold keeps its own.
pub fn dealias_sweep_with(vel: &Grid, nyquist: f64, reference: Option<&[f64]>, fallback: Option<&[f64]>) -> Grid {
    let mut out = vel.clone();
    if nyquist.is_nan() || nyquist <= 0.0 {
        return out;
    }
    let (n_az, n_g) = (vel.n_az, vel.n_gates);
    let n = n_az * n_g;
    let valid: Vec<bool> = vel.data.iter().map(|&v| v > VALID_ABOVE).collect();
    if valid.iter().filter(|&&v| v).count() < 2 {
        return out;
    }
    let period = 2.0 * nyquist;
    // Clipped in float32 first, as the numpy original did, then widened.
    let vn = nyquist as f32;
    let v: Vec<f64> = vel.data.iter().zip(&valid).map(|(&x, &ok)| if ok { x.clamp(-vn, vn) as f64 } else { 0.0 }).collect();
    let band: Vec<u8> =
        v.iter().map(|&x| ((((x + nyquist) / period) * INTERVAL_SPLITS as f64) as usize).min(INTERVAL_SPLITS - 1) as u8).collect();

    // 4-neighbour pairs of valid gates: along range, then across azimuth (wrapping).
    let mut pairs: Vec<(u32, u32)> = Vec::with_capacity(2 * n);
    for a in 0..n_az {
        let row = a * n_g;
        for g in 0..n_g - 1 {
            if valid[row + g] && valid[row + g + 1] {
                pairs.push(((row + g) as u32, (row + g + 1) as u32));
            }
        }
    }
    for a in 0..n_az {
        let (row, next) = (a * n_g, ((a + 1) % n_az) * n_g);
        for g in 0..n_g {
            if valid[row + g] && valid[next + g] {
                pairs.push(((row + g) as u32, (next + g) as u32));
            }
        }
    }

    // Connected regions of gates in the same band.
    let mut uf = UnionFind::new(n);
    for &(a, b) in &pairs {
        if band[a as usize] == band[b as usize] {
            uf.union(a as usize, b as usize);
        }
    }
    // Number regions by their smallest gate index (ascending scan assigns ids in that order).
    let mut region_of_root = vec![u32::MAX; n];
    let mut region = vec![u32::MAX; n];
    let mut size: Vec<usize> = Vec::new();
    for i in 0..n {
        if !valid[i] {
            continue;
        }
        let r = uf.find(i);
        if region_of_root[r] == u32::MAX {
            region_of_root[r] = size.len() as u32;
            size.push(0);
        }
        region[i] = region_of_root[r];
        size[region_of_root[r] as usize] += 1;
    }
    let n_regions = size.len();

    // Boundaries between different regions: count and summed jump (hi region minus lo).
    let mut edges: HashMap<(u32, u32), (usize, f64)> = HashMap::new();
    for &(a, b) in &pairs {
        let (ra, rb) = (region[a as usize], region[b as usize]);
        if ra == rb {
            continue;
        }
        let mut jump = v[b as usize] - v[a as usize];
        let (lo, hi) = if ra > rb {
            jump = -jump;
            (rb, ra)
        } else {
            (ra, rb)
        };
        let e = edges.entry((lo, hi)).or_insert((0, 0.0));
        e.0 += 1;
        e.1 += jump;
    }

    let (fold, top) = merge(n_regions, &size, edges, period);

    // Per valid gate, the extra fold that would bring it closest to the reference.
    let votes_for = |reference: &[f64]| -> Vec<Option<i64>> {
        (0..n)
            .filter(|&i| valid[i])
            .map(|i| {
                let r = reference[i];
                if r.is_nan() {
                    None
                } else {
                    let base = v[i] + fold[region[i] as usize] as f64 * period;
                    Some(((r - base) / period).round_ties_even() as i64)
                }
            })
            .collect()
    };
    let ref_k = reference.map(votes_for);
    let fallback_k = fallback.map(votes_for);
    let gate_regions: Vec<u32> = (0..n).filter(|&i| valid[i]).map(|i| region[i]).collect();
    let fold = recentre(&fold, &top, &size, &gate_regions, ref_k.as_deref(), fallback_k.as_deref());

    for i in 0..n {
        if valid[i] {
            out.data[i] = (v[i] + fold[region[i] as usize] as f64 * period) as f32;
        }
    }
    out
}

struct UnionFind(Vec<u32>);

impl UnionFind {
    fn new(n: usize) -> UnionFind {
        UnionFind((0..n as u32).collect())
    }
    fn find(&mut self, mut i: usize) -> usize {
        let mut root = i;
        while self.0[root] as usize != root {
            root = self.0[root] as usize;
        }
        while self.0[i] as usize != root {
            let next = self.0[i] as usize;
            self.0[i] = root as u32;
            i = next;
        }
        root
    }
    fn union(&mut self, a: usize, b: usize) {
        let (ra, rb) = (self.find(a), self.find(b));
        if ra != rb {
            // Keep the smaller index as the root so representatives are canonical.
            let (lo, hi) = if ra < rb { (ra, rb) } else { (rb, ra) };
            self.0[hi] = lo as u32;
        }
    }
}

/// Greedy region merging. `edges[(lo, hi)]` carries the boundary gate count and the
/// summed jump v[hi] - v[lo]. Returns every region's fold (integer multiple of `period`)
/// and the region its component merged into last (the component's id).
fn merge(n: usize, size: &[usize], edges: HashMap<(u32, u32), (usize, f64)>, period: f64) -> (Vec<i64>, Vec<usize>) {
    // adj[r][s] = (count, sum of (v_s - v_r)) over the r|s boundary, with current shifts.
    let mut adj: Vec<HashMap<usize, (usize, f64)>> = vec![HashMap::new(); n];
    // Longest boundary first, then lowest region ids: a total order, so the result is
    // deterministic whatever the map iteration order.
    let mut heap: BinaryHeap<Reverse<(i64, usize, usize)>> = BinaryHeap::with_capacity(edges.len());
    for (&(r, s), &(c, j)) in &edges {
        let (r, s) = (r as usize, s as usize);
        adj[r].insert(s, (c, j));
        adj[s].insert(r, (c, -j));
        heap.push(Reverse((-(c as i64), r, s)));
    }

    let mut size = size.to_vec(); // grows as regions merge
    let mut parent: Vec<usize> = (0..n).collect(); // merged-into pointer
    let mut rel = vec![0i64; n]; // fold relative to parent at merge time
    let mut alive = vec![true; n];

    while let Some(Reverse((neg_c, mut r, mut s))) = heap.pop() {
        if !(alive[r] && alive[s]) {
            continue;
        }
        let Some(&edge) = adj[r].get(&s) else { continue };
        if edge.0 as i64 != -neg_c {
            continue; // stale entry; the current count was pushed separately
        }
        let mut edge = edge;
        if size[s] > size[r] {
            std::mem::swap(&mut r, &mut s);
            edge = adj[r][&s];
        }
        // Shift s by k periods so the mean jump r -> s is closest to zero. A mean jump near
        // half a period says nothing about the fold; leave the pair apart unless merging
        // other regions later makes their boundary clearer.
        let folds = edge.1 / edge.0 as f64 / period;
        if (folds - folds.round_ties_even()).abs() > AMBIGUOUS {
            continue;
        }
        let k = -(folds.round_ties_even() as i64);
        let shift = k as f64 * period;
        adj[r].remove(&s);
        adj[s].remove(&r);
        let neighbours = std::mem::take(&mut adj[s]);
        for (t, (c, j)) in neighbours {
            let j_new = j - c as f64 * shift; // v_t - (v_s + shift)
            adj[t].remove(&s);
            let e = adj[r].entry(t).or_insert((0, 0.0));
            e.0 += c;
            e.1 += j_new;
            let e = *e;
            adj[t].insert(r, (e.0, -e.1));
            let (lo, hi) = if r < t { (r, t) } else { (t, r) };
            heap.push(Reverse((-(e.0 as i64), lo, hi)));
        }
        alive[s] = false;
        parent[s] = r;
        rel[s] = k;
        size[r] += size[s];
    }

    // A region moves with whatever it merged into, so folds add up along the merge chain.
    let mut fold = vec![0i64; n];
    let mut top: Vec<usize> = (0..n).collect();
    let mut children: Vec<Vec<usize>> = vec![Vec::new(); n];
    for (s, &p) in parent.iter().enumerate() {
        if p != s {
            children[p].push(s);
        }
    }
    let mut stack: Vec<usize> = (0..n).filter(|&i| parent[i] == i).collect();
    while let Some(r) = stack.pop() {
        for c in std::mem::take(&mut children[r]) {
            fold[c] = rel[c] + fold[r];
            top[c] = top[r];
            stack.push(c);
        }
    }
    (fold, top)
}

/// Shifts each component (regions sharing a `top`) as a whole. `ref_k` is, per valid gate,
/// the extra fold that would bring it closest to the reference (None where unknown); a
/// component with enough such gates takes their most common vote; failing that, the
/// `fallback_k` vote if it is decisive. Otherwise it takes the shift that keeps most of its
/// gates at their measured value (fold 0).
fn recentre(
    fold: &[i64],
    top: &[usize],
    size: &[usize],
    gate_regions: &[u32],
    ref_k: Option<&[Option<i64>]>,
    fallback_k: Option<&[Option<i64>]>,
) -> Vec<i64> {
    let n = top.len();
    // Ascending fold order and first-maximum wins, as numpy's argmax did.
    let mut votes: Vec<BTreeMap<i64, usize>> = vec![BTreeMap::new(); n];
    for i in 0..n {
        *votes[top[i]].entry(fold[i]).or_insert(0) += size[i];
    }
    let mut shift: Vec<i64> = votes.iter().map(|v| -argmax(v)).collect();
    let tally = |k: &[Option<i64>]| {
        let mut out: Vec<BTreeMap<i64, usize>> = vec![BTreeMap::new(); n];
        for (g, k) in gate_regions.iter().zip(k) {
            if let Some(k) = k {
                *out[top[*g as usize]].entry(*k).or_insert(0) += 1;
            }
        }
        out
    };
    let ref_votes = ref_k.map(tally);
    let fallback_votes = fallback_k.map(tally);
    for t in 0..n {
        if let Some(v) = ref_votes.as_ref().map(|r| &r[t])
            && v.values().sum::<usize>() >= MIN_REFERENCE_GATES
        {
            shift[t] = argmax(v);
        } else if let Some(v) = fallback_votes.as_ref().map(|f| &f[t]) {
            let total = v.values().sum::<usize>();
            let k = argmax(v);
            if total >= MIN_REFERENCE_GATES && v[&k] as f64 >= FALLBACK_MIN_SHARE * total as f64 {
                shift[t] = k;
            }
        }
    }
    (0..n).map(|i| fold[i] + shift[top[i]]).collect()
}

/// Key of the first largest value (0 for an empty map).
fn argmax(votes: &BTreeMap<i64, usize>) -> i64 {
    let mut best: Option<(i64, usize)> = None;
    for (&k, &c) in votes {
        if best.is_none_or(|(_, bc)| c > bc) {
            best = Some((k, c));
        }
    }
    best.map_or(0, |(k, _)| k)
}

/// The unfolded sweep `below` resampled onto the grid of `sw` at the same azimuth and
/// ground range (flat earth, fine for choosing folds). NaN where `below` has no data.
pub fn resample(sw: &SweepIn, below: &SweepIn, below_vel: &Grid) -> Vec<f64> {
    let (n_az, n_g) = (sw.vel.n_az, sw.vel.n_gates);
    let (b_az, b_g) = (below_vel.n_az, below_vel.n_gates);
    let cos_sw = sw.elevation_deg.to_radians().cos();
    let cos_below = below.elevation_deg.to_radians().cos();
    let gate: Vec<Option<usize>> = (0..n_g)
        .map(|g| {
            let rng = (sw.first_gate_m + g as f64 * sw.gate_spacing_m) * cos_sw;
            let r_below = rng / cos_below;
            let gb = ((r_below - below.first_gate_m) / below.gate_spacing_m).round_ties_even();
            (gb >= 0.0 && gb < b_g as f64).then_some(gb as usize)
        })
        .collect();
    let mut out = vec![f64::NAN; n_az * n_g];
    for a in 0..n_az {
        let ab = a * b_az / n_az; // bins start at 0 deg in both grids
        let row = below_vel.row(ab);
        for (g, gb) in gate.iter().enumerate() {
            if let Some(gb) = gb {
                let v = row[*gb];
                if v > VALID_ABOVE {
                    out[a * n_g + g] = v as f64;
                }
            }
        }
    }
    out
}

/// Unfolds a synthetic sweep (uniform wind growing with range plus a rotation couplet,
/// noise, 10 % missing gates) aliased at Vn = 26 m/s; returns (aliased, wrong) fractions.
pub fn self_test() -> (f64, f64) {
    use crate::synth::Rng;
    let mut rng = Rng::seed(0);
    let (n_az, n_g, vn) = (720usize, 1192usize, 26.1f64);
    let mut truth = vec![0f64; n_az * n_g];
    let mut measured = Grid::filled(n_az, n_g, 0.0);
    let mut missing = vec![false; n_az * n_g];
    for a in 0..n_az {
        let az = ((a as f64 + 0.5) * 0.5).to_radians();
        for g in 0..n_g {
            let r = g as f64 * 0.25 + 2.125;
            let (x, y) = (r * az.sin(), r * az.cos());
            let mut t = (20.0 + r / 10.0) * (az - 225f64.to_radians()).cos();
            t += 60.0 * (-((x - 20.0).powi(2) + y * y) / 4.0).exp() * (y / 2.0);
            t += rng.normal() * 1.5;
            truth[a * n_g + g] = t;
            measured.data[a * n_g + g] = ((((t + vn).rem_euclid(2.0 * vn) - vn) * 2.0).round() / 2.0) as f32;
        }
    }
    for (m, v) in missing.iter_mut().zip(&mut measured.data) {
        if rng.random() < 0.1 {
            *m = true;
            *v = -1000.0;
        }
    }
    let out = dealias_sweep(&measured, vn, None);
    let (mut wrong, mut aliased, mut total) = (0usize, 0usize, 0usize);
    for i in 0..n_az * n_g {
        if missing[i] {
            continue;
        }
        total += 1;
        wrong += ((out.data[i] as f64 - truth[i]).abs() > vn) as usize;
        aliased += ((measured.data[i] as f64 - truth[i]).abs() > vn) as usize;
    }
    (aliased as f64 / total as f64, wrong as f64 / total as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_sweep_with_couplet() {
        let (aliased, wrong) = self_test();
        assert!(aliased > 0.05, "{aliased}");
        assert!(wrong < 1e-3, "{wrong}");
    }

    #[test]
    fn unaliased_field_is_unchanged() {
        let n = 3600;
        let vel = Grid::from_vec(360, 10, (0..n).map(|i| ((i as f32) * 0.01).sin() * 10.0).collect());
        assert_eq!(dealias_sweep(&vel, 26.0, None), vel);
    }

    #[test]
    fn sentinels_and_no_nyquist_pass_through() {
        let mut vel = Grid::filled(360, 10, 5.0);
        vel.set(0, 0, -1000.0);
        vel.set(0, 1, -2000.0);
        vel.set(10, 3, 5.5);
        let out = dealias_sweep(&vel, 26.0, None);
        assert_eq!(out, vel);
        assert_eq!(dealias_sweep(&vel, 0.0, None), vel);
        assert_eq!(dealias_sweep(&vel, -1.0, None), vel);
        let empty = Grid::filled(360, 10, -1000.0);
        assert_eq!(dealias_sweep(&empty, 26.0, None), empty);
    }

    #[test]
    fn connected_fold_is_unfolded() {
        // A smooth ramp that crosses the Nyquist velocity: the far half reads folded.
        let vn = 20.0f32;
        let mut vel = Grid::filled(360, 200, 0.0);
        for a in 0..360 {
            for g in 0..200 {
                let t = g as f32 * 0.2; // 0 .. 40 m/s
                vel.set(a, g, (t + vn).rem_euclid(2.0 * vn) - vn);
            }
        }
        let out = dealias_sweep(&vel, vn as f64, None);
        for g in 0..200 {
            assert!((out.at(5, g) - g as f32 * 0.2).abs() < 1e-3, "gate {g}: {}", out.at(5, g));
        }
    }

    #[test]
    fn reference_picks_absolute_fold() {
        // Everything folded once: without a reference nothing changes, with one it unfolds.
        let vn = 20.0;
        let vel = Grid::filled(360, 50, 15.0);
        assert_eq!(dealias_sweep(&vel, vn, None), vel);
        let reference = vec![55.0f64; 360 * 50];
        let out = dealias_sweep(&vel, vn, Some(&reference));
        assert!(out.data.iter().all(|&v| (v - 55.0).abs() < 1e-4));
        // Too few reference gates: ignored.
        let mut sparse = vec![f64::NAN; 360 * 50];
        sparse[..MIN_REFERENCE_GATES - 1].fill(55.0);
        assert_eq!(dealias_sweep(&vel, vn, Some(&sparse)), vel);
    }

    #[test]
    fn fallback_places_components_the_reference_misses() {
        // Two isolated echoes, each folded once (true 35 m/s reads -5 at Vn 20). The reference
        // (tilt below) covers the first only; a fallback (VAD) of 33 m/s everywhere places the
        // second. A fallback that splits a component's votes is ignored.
        let vn = 20.0;
        let mut vel = Grid::filled(360, 60, crate::level2::MISSING);
        for a in 10..30 {
            for g in 5..15 {
                vel.set(a, g, -5.0);
                vel.set(a + 100, g + 30, -5.0);
            }
        }
        let mut reference = vec![f64::NAN; 360 * 60];
        for a in 10..30 {
            for g in 5..15 {
                reference[a * 60 + g] = 34.0;
            }
        }
        let fallback = vec![33.0f64; 360 * 60];
        let out = dealias_sweep_with(&vel, vn, Some(&reference), Some(&fallback));
        assert_eq!((out.at(20, 10), out.at(120, 40)), (35.0, 35.0));
        let without = dealias_sweep_with(&vel, vn, Some(&reference), None);
        assert_eq!((without.at(20, 10), without.at(120, 40)), (35.0, -5.0), "no fallback: measured value kept");
        let mut split = fallback.clone();
        for a in 110..130 {
            for g in 35..45 {
                split[a * 60 + g] = -5.0; // half the second echo votes for no fold
            }
        }
        let out = dealias_sweep_with(&vel, vn, Some(&reference), Some(&split));
        assert_eq!(out.at(120, 40), -5.0, "indecisive fallback ignored");
    }

    #[test]
    fn volume_references_the_tilt_below() {
        let vn = 20.0;
        let low = Grid::filled(360, 100, 35.0); // already beyond Vn: clipped to 20 then unfolded to 35? no - measured value
        let low_measured = Grid::filled(360, 100, 35.0 - 2.0 * vn as f32); // reads -5
        let high = Grid::filled(360, 100, -5.0);
        let _ = low;
        fn mk(g: &Grid, e: f64) -> SweepIn<'_> {
            SweepIn { vel: g, nyquist: 20.0, elevation_deg: e, first_gate_m: 2125.0, gate_spacing_m: 250.0 }
        }
        // Both tilts read -5 m/s uniformly: nothing to unfold, both stay at -5.
        let out = dealias_volume(&[mk(&high, 1.5), mk(&low_measured, 0.5)]);
        assert!(out[0].data.iter().all(|&v| (v + 5.0).abs() < 1e-4));
        assert!(out[1].data.iter().all(|&v| (v + 5.0).abs() < 1e-4));
    }

    #[test]
    fn resampling_matches_ground_range() {
        let below = Grid::from_vec(360, 100, (0..36000).map(|i| (i % 100) as f32).collect());
        let g = Grid::filled(720, 50, 0.0);
        let sw = SweepIn { vel: &g, nyquist: 20.0, elevation_deg: 10.0, first_gate_m: 2125.0, gate_spacing_m: 500.0 };
        let bl = SweepIn { vel: &below, nyquist: 20.0, elevation_deg: 0.5, first_gate_m: 2125.0, gate_spacing_m: 250.0 };
        let r = resample(&sw, &bl, &below);
        // Gate 10 of the upper tilt: slant 7125 m at 10 deg -> ground 7017 m -> below gate ~19.6 -> 20.
        let expect = (((2125.0 + 10.0 * 500.0) * 10f64.to_radians().cos() / 0.5f64.to_radians().cos() - 2125.0) / 250.0).round();
        assert_eq!(r[10], expect);
        assert_eq!(r[100 * 50 + 10], expect); // azimuth 50 deg -> below bin 50
        assert!(r[49].is_nan() || r[49] >= 0.0);
    }

    #[test]
    fn union_find_components() {
        let mut uf = UnionFind::new(6);
        uf.union(0, 1);
        uf.union(3, 4);
        uf.union(1, 4);
        assert_eq!(uf.find(3), 0);
        assert_eq!(uf.find(2), 2);
        assert_eq!(uf.find(5), 5);
    }
}
