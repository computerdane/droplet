"""VAD wind profile and Bunkers storm motion from one volume (numpy only).

VAD (velocity-azimuth display): on a ring of constant slant range r in a sweep at
elevation e, a horizontally uniform wind (u east, v north) plus a vertical motion w shows
up as a sinusoid in azimuth phi (clockwise from north):

    Vr(phi) = a0 + cos(e) * (u * sin(phi) + v * cos(phi)),   a0 = w * sin(e)

so a least-squares fit of [1, sin, cos] per ring gives u and v at the beam height of that
ring. Rings are blocks of RING_GATES gates; each is fitted twice: first on the dealiased
velocity, then on the raw velocity unfolded against that first fit (value = model +
residual wrapped into +-Vn), dropping outliers. The second pass makes the fit immune to
dealiasing mistakes. Rings with poor azimuthal coverage or a large residual are rejected;
the rest are binned by height (median per HEIGHT_BIN_M layer).

Bunkers et al. (2000) internal-dynamics method on the 0-6 km profile: the right mover is
7.5 m/s to the right of the 0-6 km shear vector from the 0-6 km mean wind (left mover:
to the left). Storm-relative helicity for 0-1 and 0-3 km is computed against the right
mover.
"""

from __future__ import annotations

import numpy as np

VALID_ABOVE = -900.0
RING_GATES = 4  # gates per VAD ring (1 km at 250 m spacing)
MIN_RANGE_M = 5_000.0
MAX_RANGE_M = 60_000.0  # the wind must be roughly uniform across the ring
MAX_ELEVATION_DEG = 20.0
MIN_COVERAGE = 0.25  # share of a ring's samples that must be valid
SECTORS = 8  # every 45-degree sector needs samples, or the sinusoid is unconstrained
MIN_PER_SECTOR = 6
MAX_RMS_MS = 4.5
HEIGHT_BIN_M = 250.0
MAX_HEIGHT_M = 12_000.0
MIN_RINGS_PER_BIN = 2
EARTH_RADIUS_M = 6_371_000.0 * 4.0 / 3.0  # 4/3-earth beam model, as in the shaders
BUNKERS_DEVIATION_MS = 7.5


def beam_height_m(slant_m: np.ndarray, elevation_deg: float) -> np.ndarray:
    e = np.radians(elevation_deg)
    r = EARTH_RADIUS_M
    return np.sqrt(slant_m**2 + r**2 + 2.0 * slant_m * r * np.sin(e)) - r


def fit_rings(
    dvel: np.ndarray,
    vel: np.ndarray | None,
    nyquist: float,
    elevation_deg: float,
    first_gate_m: float,
    gate_spacing_m: float,
) -> list[tuple[float, float, float, float]]:
    """VAD fits for one sweep: [(height_m, u, v, rms)] for every ring that passes the checks."""
    if elevation_deg > MAX_ELEVATION_DEG:
        return []
    n_az, n_g = dvel.shape
    g0 = max(int(np.ceil((MIN_RANGE_M - first_gate_m) / gate_spacing_m)), 0)
    g1 = min(int((MAX_RANGE_M - first_gate_m) / gate_spacing_m), n_g)
    n_rings = (g1 - g0) // RING_GATES
    if n_rings <= 0:
        return []
    g1 = g0 + n_rings * RING_GATES

    def rings(a: np.ndarray) -> np.ndarray:  # [ring][azimuth * RING_GATES]
        a = a[:, g0:g1].reshape(n_az, n_rings, RING_GATES)
        return a.transpose(1, 0, 2).reshape(n_rings, n_az * RING_GATES).astype(np.float64)

    az = np.radians((np.arange(n_az) + 0.5) * 360.0 / n_az)
    s = np.repeat(np.sin(az), RING_GATES)[None, :]
    c = np.repeat(np.cos(az), RING_GATES)[None, :]
    sector = np.repeat(np.arange(n_az) * SECTORS // n_az, RING_GATES)

    y = rings(dvel)
    ok = y > VALID_ABOVE
    coef, rms = _fit(y, ok, s, c)
    if vel is not None and nyquist > 0:
        raw = rings(vel)
        ok &= raw > VALID_ABOVE
        model = coef[:, :1] + coef[:, 1:2] * s + coef[:, 2:3] * c
        res = (raw - model + nyquist) % (2.0 * nyquist) - nyquist
        y = model + res
        ok &= np.abs(res) < 3.0 * np.maximum(rms, 2.0)[:, None]
        coef, rms = _fit(y, ok, s, c)

    n_valid = ok.sum(axis=1)
    per_sector = np.stack([(ok & (sector == k)).sum(axis=1) for k in range(SECTORS)], axis=1)
    good = (
        (n_valid >= MIN_COVERAGE * y.shape[1])
        & (per_sector.min(axis=1) >= MIN_PER_SECTOR)
        & (rms <= MAX_RMS_MS)
    )
    cos_e = np.cos(np.radians(elevation_deg))
    slant = first_gate_m + (g0 + (np.arange(n_rings) + 0.5) * RING_GATES - 0.5) * gate_spacing_m
    height = beam_height_m(slant, elevation_deg)
    return [
        (float(height[i]), float(coef[i, 1] / cos_e), float(coef[i, 2] / cos_e), float(rms[i]))
        for i in np.flatnonzero(good)
    ]


def _fit(y: np.ndarray, ok: np.ndarray, s: np.ndarray, c: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Per-row least squares of y ~ a0 + a1 sin + a2 cos over the `ok` samples.
    Returns coefficients [row][3] and the rms residual per row (inf where singular)."""
    w = ok.astype(np.float64)
    yw = np.where(ok, y, 0.0)
    ss, cc = s * np.ones_like(w), c * np.ones_like(w)
    basis = [np.ones_like(w), ss, cc]
    ata = np.empty((y.shape[0], 3, 3))
    atb = np.empty((y.shape[0], 3))
    for i in range(3):
        atb[:, i] = (basis[i] * yw).sum(axis=1)
        for j in range(i, 3):
            ata[:, i, j] = ata[:, j, i] = (basis[i] * basis[j] * w).sum(axis=1)
    det = np.linalg.det(ata)
    solvable = np.abs(det) > 1e-6 * np.maximum(ata[:, 0, 0], 1.0) ** 3
    ata[~solvable] = np.eye(3)
    coef = np.linalg.solve(ata, atb[:, :, None])[:, :, 0]
    model = coef[:, :1] + coef[:, 1:2] * ss + coef[:, 2:3] * cc
    n = np.maximum(w.sum(axis=1), 1.0)
    rms = np.sqrt((((yw - model) * w) ** 2).sum(axis=1) / n)
    rms[~solvable] = np.inf
    return coef, rms


def wind_profile(sweeps: list[dict]) -> dict | None:
    """Height-binned VAD profile from the sweeps of one volume. Each dict has "dvel", "vel"
    (raw, or None), "nyquist", "elevation_deg", "first_gate_m", "gate_spacing_m". Returns
    {"height_m", "u_ms", "v_ms", "n"} (parallel lists, heights above the radar at bin
    centres) or None when no ring passed."""
    fits = []
    for sw in sweeps:
        fits += fit_rings(
            sw["dvel"], sw.get("vel"), sw["nyquist"], sw["elevation_deg"], sw["first_gate_m"], sw["gate_spacing_m"]
        )
    if not fits:
        return None
    h, u, v, _ = (np.array(a) for a in zip(*fits))
    b = np.floor(h / HEIGHT_BIN_M).astype(np.int64)
    out: dict[str, list] = {"height_m": [], "u_ms": [], "v_ms": [], "n": []}
    for k in np.unique(b[(b >= 0) & (h < MAX_HEIGHT_M)]):
        sel = b == k
        if sel.sum() < MIN_RINGS_PER_BIN:
            continue
        out["height_m"].append(round(float((k + 0.5) * HEIGHT_BIN_M), 1))
        out["u_ms"].append(round(float(np.median(u[sel])), 2))
        out["v_ms"].append(round(float(np.median(v[sel])), 2))
        out["n"].append(int(sel.sum()))
    return out if out["height_m"] else None


def bunkers(profile: dict | None) -> dict | None:
    """Bunkers right/left mover from a wind_profile(), or None when the profile does not
    reach from near the ground (<= 1 km) to near 6 km (>= 5 km). Vectors are [u, v] m/s."""
    if not profile:
        return None
    h = np.asarray(profile["height_m"])
    u = np.asarray(profile["u_ms"])
    v = np.asarray(profile["v_ms"])
    if h.min() > 1000.0 or h.max() < 5000.0:
        return None
    z = np.arange(0.0, 6000.0 + 1.0, HEIGHT_BIN_M)
    uz, vz = np.interp(z, h, u), np.interp(z, h, v)
    mean = np.array([uz.mean(), vz.mean()])
    low, high = z <= 500.0, z >= 5500.0
    shear = np.array([uz[high].mean() - uz[low].mean(), vz[high].mean() - vz[low].mean()])
    norm = np.hypot(*shear)
    if norm < 1e-3:
        return None
    right = np.array([shear[1], -shear[0]]) / norm * BUNKERS_DEVIATION_MS
    rm, lm = mean + right, mean - right
    return {
        "method": "bunkers",
        "right": _vec(rm),
        "left": _vec(lm),
        "mean_0_6km": _vec(mean),
        "shear_0_6km": _vec(shear),
        "srh_0_1km": round(_srh(z, uz, vz, rm, 1000.0), 1),
        "srh_0_3km": round(_srh(z, uz, vz, rm, 3000.0), 1),
    }


def _srh(z: np.ndarray, u: np.ndarray, v: np.ndarray, storm: np.ndarray, top: float) -> float:
    """Storm-relative helicity (m^2/s^2) from the ground to `top`."""
    k = z <= top
    su, sv = u[k] - storm[0], v[k] - storm[1]
    return float(np.sum(su[1:] * sv[:-1] - su[:-1] * sv[1:]))


def _vec(a: np.ndarray) -> list[float]:
    return [round(float(a[0]), 2), round(float(a[1]), 2)]


def _self_test() -> None:
    """python -m nexrad.vad: recover a veering, strengthening wind profile from synthetic
    aliased sweeps with noise, missing gates and a blob of badly dealiased gates."""
    rng = np.random.default_rng(1)
    n_az, n_g, vn = 720, 1192, 26.0

    def truth(hgt):  # 10 m/s from the south at the ground veering to 30 m/s from the west at 6 km
        f = np.clip(hgt / 6000.0, 0.0, 1.5)
        spd = 10.0 + 20.0 * f
        ang = np.radians(180.0 + 90.0 * f)  # direction it blows from
        return -spd * np.sin(ang), -spd * np.cos(ang)

    az = np.radians((np.arange(n_az) + 0.5) * 0.5)[:, None]
    slant = 2125.0 + np.arange(n_g)[None, :] * 250.0
    sweeps = []
    for elev in (0.5, 0.9, 1.3, 1.8, 2.4, 3.1, 4.0, 5.1, 6.4, 8.0, 10.0, 12.5, 15.6, 19.5):
        u, v = truth(beam_height_m(slant, elev))
        cos_e = np.cos(np.radians(elev))
        true = cos_e * (u * np.sin(az) + v * np.cos(az)) + rng.normal(0.0, 1.5, (n_az, n_g))
        raw = (true + vn) % (2 * vn) - vn
        dvel = true.copy()
        dvel[100:140, 200:260] += 2 * vn  # a region the dealiaser got one fold wrong
        missing = rng.random(true.shape) < 0.3
        raw[missing] = dvel[missing] = -1000.0
        sweeps.append(
            {"dvel": dvel, "vel": raw, "nyquist": vn, "elevation_deg": elev, "first_gate_m": 2125.0, "gate_spacing_m": 250.0}
        )
    prof = wind_profile(sweeps)
    assert prof is not None
    h = np.array(prof["height_m"])
    tu, tv = truth(h)
    err = np.hypot(np.array(prof["u_ms"]) - tu, np.array(prof["v_ms"]) - tv)
    print(f"{len(h)} levels {h.min():.0f}-{h.max():.0f} m, max error {err.max():.2f} m/s")
    assert err.max() < 1.5
    bk = bunkers(prof)
    print("bunkers:", bk)
    assert bk is not None and bk["srh_0_3km"] > 0


if __name__ == "__main__":
    _self_test()
