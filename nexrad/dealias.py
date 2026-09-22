"""Region-based Doppler velocity dealiasing (numpy only).

Radial velocity is only measured modulo 2*Vn (Vn = Nyquist velocity): a true 30 m/s at
Vn = 26 reads as -22. Unfolding one sweep:

1. Split the Nyquist interval into a few bands and label connected regions of gates in
   the same band (4-neighbour, azimuth wraps around). A fold cannot hide inside a region.
2. For every pair of touching regions, count the boundary gates and sum the velocity
   jump across them.
3. Repeatedly merge the pair with the longest shared boundary: shift the smaller region
   by the multiple of 2*Vn that makes the mean jump smallest, then combine their
   boundaries with the neighbours (the merged region's jumps are recomputed with the shift).
   Boundaries whose mean jump is close to Vn are ambiguous and not merged across.
4. Each connected component ends up with one set of relative folds; shift it as a whole.
   With a reference (the already unfolded tilt below, see dealias_volume) the shift is the
   one most of its gates agree with the reference on; otherwise it is the one that keeps
   most of its gates at their measured value.

This follows the idea of Py-ART's dealias_region_based without its SciPy dependency.
"""

from __future__ import annotations

import heapq

import numpy as np

VALID_ABOVE = -900.0  # MISSING = -1000, RANGE_FOLDED = -2000
INTERVAL_SPLITS = 3
AMBIGUOUS = 0.4  # skip merges whose mean jump is within this of half a period (in periods)
MIN_REFERENCE_GATES = 20  # a component needs this many gates overlapping the reference


def dealias_volume(sweeps: list[dict]) -> list[np.ndarray]:
    """Unfold every sweep of a volume, lowest elevation first, each one referenced to the
    closest sweep at or below its elevation that is already done. Each dict has "vel",
    "nyquist", "elevation_deg", "first_gate_m", "gate_spacing_m"; results come back in the
    same order."""
    order = sorted(range(len(sweeps)), key=lambda i: sweeps[i]["elevation_deg"])
    out: list[np.ndarray | None] = [None] * len(sweeps)
    below: dict | None = None
    for i in order:
        sw = sweeps[i]
        ref = _reference(sw, below) if below is not None else None
        out[i] = dealias_sweep(sw["vel"], sw["nyquist"], reference=ref)
        below = dict(sw, vel=out[i])
    return out


def dealias_sweep(
    vel: np.ndarray,
    nyquist: float,
    reference: np.ndarray | None = None,
    splits: int = INTERVAL_SPLITS,
) -> np.ndarray:
    """Unfold one sweep. `vel` is [azimuth_bin][gate] float32 with sentinels (< -900), which
    are kept as they are. `reference`, if given, is an unfolded estimate on the same grid
    (NaN where unknown) used to pick each component's absolute fold. Returns float32."""
    out = vel.astype(np.float32, copy=True)
    if not nyquist or nyquist <= 0:
        return out
    n_az, n_g = vel.shape
    valid = vel > VALID_ABOVE
    if valid.sum() < 2:
        return out
    v = np.clip(np.where(valid, vel, 0.0), -nyquist, nyquist).astype(np.float64)
    band = np.minimum(((v + nyquist) / (2.0 * nyquist) * splits).astype(np.int64), splits - 1)

    a, b = _neighbour_pairs(valid)
    flat_v = v.ravel()
    flat_band = band.ravel()
    same = flat_band[a] == flat_band[b]
    root = _components(n_az * n_g, a[same], b[same])

    gates = np.flatnonzero(valid.ravel())
    region_ids, region_of_gate = np.unique(root[gates], return_inverse=True)
    n_regions = region_ids.size
    region = np.full(n_az * n_g, -1, dtype=np.int64)
    region[gates] = region_of_gate
    size = np.bincount(region_of_gate, minlength=n_regions)

    # Boundaries between different regions: count and summed jump (hi region minus lo).
    ra, rb = region[a], region[b]
    cross = ra != rb
    ra, rb = ra[cross], rb[cross]
    jump = flat_v[b[cross]] - flat_v[a[cross]]
    flip = ra > rb
    lo = np.where(flip, rb, ra)
    hi = np.where(flip, ra, rb)
    jump = np.where(flip, -jump, jump)
    keys, inv = np.unique(lo * n_regions + hi, return_inverse=True)
    counts = np.bincount(inv)
    sums = np.bincount(inv, weights=jump)

    fold, top = _merge(n_regions, size, keys // n_regions, keys % n_regions, counts, sums, 2.0 * nyquist)
    ref_k = None
    if reference is not None:
        ref = reference.ravel()[gates]
        known = ~np.isnan(ref)
        ref_k = np.full(gates.size, np.iinfo(np.int64).min)
        base = flat_v[gates] + fold[region_of_gate] * 2.0 * nyquist
        ref_k[known] = np.round((ref[known] - base[known]) / (2.0 * nyquist)).astype(np.int64)
    fold = _recentre(fold, top, size, region_of_gate, ref_k)

    unfolded = np.full(n_az * n_g, np.nan)
    unfolded[gates] = flat_v[gates] + fold[region_of_gate] * 2.0 * nyquist
    out[valid] = unfolded.reshape(n_az, n_g)[valid]
    return out


def _neighbour_pairs(valid: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Flat indices (a, b) of 4-neighbour gate pairs where both gates are valid. Azimuth
    wraps (last bin touches the first); range does not."""
    n_az, n_g = valid.shape
    idx = np.arange(n_az * n_g, dtype=np.int64).reshape(n_az, n_g)
    along = valid[:, :-1] & valid[:, 1:]
    a1, b1 = idx[:, :-1][along], idx[:, 1:][along]
    nxt = np.roll(idx, -1, axis=0)
    across = valid & np.roll(valid, -1, axis=0)
    a2, b2 = idx[across], nxt[across]
    return np.concatenate([a1, a2]), np.concatenate([b1, b2])


def _components(n: int, a: np.ndarray, b: np.ndarray) -> np.ndarray:
    """Connected components of the graph on n nodes with edges (a, b): returns each node's
    root (the smallest index in its component). Vectorised union-find: hook every root to
    the smallest root it touches, then compress paths by pointer jumping, until stable."""
    parent = np.arange(n, dtype=np.int64)
    while a.size:
        pa, pb = parent[a], parent[b]
        open_ = pa != pb
        a, b, pa, pb = a[open_], b[open_], pa[open_], pb[open_]
        if not a.size:
            break
        np.minimum.at(parent, np.maximum(pa, pb), np.minimum(pa, pb))
        while True:
            jumped = parent[parent]
            if np.array_equal(jumped, parent):
                break
            parent = jumped
    return parent


def _merge(
    n: int,
    size: np.ndarray,
    lo: np.ndarray,
    hi: np.ndarray,
    counts: np.ndarray,
    sums: np.ndarray,
    period: float,
) -> tuple[np.ndarray, np.ndarray]:
    """Greedy region merging. Edges (lo, hi) carry the boundary gate count and the summed
    jump v[hi] - v[lo]. Returns every region's fold (integer multiple of `period`) and the
    region its component merged into last (the component's id)."""
    # adj[r][s] = [count, sum of (v_s - v_r)] over the r|s boundary, with current shifts.
    adj: list[dict[int, list[float]]] = [dict() for _ in range(n)]
    heap: list[tuple[int, int, int]] = []
    for r, s, c, j in zip(lo.tolist(), hi.tolist(), counts.tolist(), sums.tolist()):
        adj[r][s] = [c, j]
        adj[s][r] = [c, -j]
        heap.append((-c, r, s))
    heapq.heapify(heap)

    size = size.astype(np.int64).tolist()  # grows as regions merge
    parent = list(range(n))  # merged-into pointer
    rel = [0] * n  # fold relative to parent at merge time
    alive = [True] * n

    while heap:
        neg_c, r, s = heapq.heappop(heap)
        if not (alive[r] and alive[s]):
            continue
        edge = adj[r].get(s)
        if edge is None or edge[0] != -neg_c:
            continue  # stale entry; the current count was pushed separately
        if size[s] > size[r]:
            r, s = s, r
            edge = adj[r][s]
        # Shift s by k periods so the mean jump r -> s is closest to zero. A mean jump near
        # half a period says nothing about the fold; leave the pair apart unless merging
        # other regions later makes their boundary clearer.
        folds = edge[1] / edge[0] / period
        if abs(folds - round(folds)) > AMBIGUOUS:
            continue
        k = -round(folds)
        shift = k * period
        del adj[r][s]
        del adj[s][r]
        for t, (c, j) in adj[s].items():
            j_new = j - c * shift  # v_t - (v_s + shift)
            del adj[t][s]
            e = adj[r].get(t)
            if e is None:
                e = adj[r][t] = [0, 0.0]
                adj[t][r] = [0, 0.0]
            e[0] += c
            e[1] += j_new
            back = adj[t][r]
            back[0] = e[0]
            back[1] = -e[1]
            heapq.heappush(heap, (-e[0], r, t) if r < t else (-e[0], t, r))
        adj[s] = {}
        alive[s] = False
        parent[s] = r
        rel[s] = k
        size[r] += size[s]

    # A region moves with whatever it merged into, so folds add up along the merge chain.
    fold = np.zeros(n, dtype=np.int64)
    top = np.arange(n, dtype=np.int64)
    children: list[list[int]] = [[] for _ in range(n)]
    for s, p in enumerate(parent):
        if p != s:
            children[p].append(s)
    stack = [i for i in range(n) if parent[i] == i]
    while stack:
        r = stack.pop()
        for c in children[r]:
            fold[c] = rel[c] + fold[r]
            top[c] = top[r]
            stack.append(c)
    return fold, top


def _recentre(
    fold: np.ndarray,
    top: np.ndarray,
    size: np.ndarray,
    region_of_gate: np.ndarray,
    ref_k: np.ndarray | None,
) -> np.ndarray:
    """Shift each component (regions sharing a `top`) as a whole. `ref_k` is, per gate, the
    extra fold that would bring it closest to the reference (int64 min where unknown); a
    component with enough such gates takes their most common vote. Otherwise it takes the
    shift that keeps most of its gates at their measured value (fold 0)."""
    n = top.size
    lo = fold.min()
    n_folds = fold.max() - lo + 1
    votes = np.bincount(top * n_folds + (fold - lo), weights=size, minlength=n * n_folds)
    shift = -(votes.reshape(n, n_folds).argmax(axis=1) + lo)
    if ref_k is not None:
        known = ref_k != np.iinfo(np.int64).min
        if known.any():
            k = ref_k[known]
            k_lo = k.min()
            n_k = k.max() - k_lo + 1
            comp = top[region_of_gate[known]]
            ref_votes = np.bincount(comp * n_k + (k - k_lo), minlength=n * n_k).reshape(n, n_k)
            enough = ref_votes.sum(axis=1) >= MIN_REFERENCE_GATES
            shift = np.where(enough, ref_votes.argmax(axis=1) + k_lo, shift)
    return fold + shift[top]


def _reference(sw: dict, below: dict) -> np.ndarray:
    """The unfolded sweep `below` resampled onto the grid of `sw` at the same azimuth and
    ground range (flat earth, fine for choosing folds). NaN where `below` has no data."""
    n_az, n_g = sw["vel"].shape
    b_az, b_g = below["vel"].shape
    rng = (sw["first_gate_m"] + np.arange(n_g) * sw["gate_spacing_m"]) * np.cos(np.radians(sw["elevation_deg"]))
    r_below = rng / np.cos(np.radians(below["elevation_deg"]))
    g = np.round((r_below - below["first_gate_m"]) / below["gate_spacing_m"]).astype(np.int64)
    inside = (g >= 0) & (g < b_g)
    a = (np.arange(n_az) * b_az) // n_az  # bins start at 0 deg in both grids
    src = below["vel"][a[:, None], np.clip(g, 0, b_g - 1)[None, :]].astype(np.float64)
    src[:, ~inside] = np.nan
    src[src <= VALID_ABOVE] = np.nan
    return src


def _self_test() -> None:
    """python -m nexrad.dealias: unfold a synthetic sweep (uniform wind growing with range
    plus a rotation couplet, noise, 10 % missing gates) aliased at Vn = 26 m/s."""
    rng = np.random.default_rng(0)
    n_az, n_g, vn = 720, 1192, 26.1
    az = np.radians((np.arange(n_az) + 0.5) * 0.5)[:, None]
    r = (np.arange(n_g) * 0.25 + 2.125)[None, :]
    x, y = r * np.sin(az), r * np.cos(az)
    true = (20 + r / 10) * np.cos(az - np.radians(225))
    true = true + 60 * np.exp(-((x - 20) ** 2 + y**2) / 4) * (y / 2)
    true = true + rng.normal(0, 1.5, true.shape)
    measured = np.round(((true + vn) % (2 * vn) - vn) * 2) / 2
    missing = rng.random(true.shape) < 0.1
    measured[missing] = -1000.0
    out = dealias_sweep(measured.astype(np.float32), vn)
    wrong = np.abs(out - true)[~missing] > vn
    aliased = np.abs(measured - true)[~missing] > vn
    print(f"aliased gates: {aliased.mean():.2%} before, {wrong.mean():.4%} after")
    assert wrong.mean() < 1e-3


if __name__ == "__main__":
    _self_test()
