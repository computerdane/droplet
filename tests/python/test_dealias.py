import numpy as np

from nexrad import dealias

VN = 20.0


def _alias(true: np.ndarray, vn: float = VN) -> np.ndarray:
    return ((true + vn) % (2 * vn) - vn).astype(np.float32)


def _wind_sweep(n_az: int = 360, n_g: int = 100) -> np.ndarray:
    """A uniform-ish wind whose radial component peaks at 24 m/s toward azimuth 0."""
    az = np.radians((np.arange(n_az) + 0.5) * 360.0 / n_az)[:, None]
    return (12.0 * np.cos(az) + 12.0 + np.zeros((1, n_g))).astype(np.float32)


def test_synthetic_sweep_with_couplet():
    """The module self-test: wind growing with range plus a rotation couplet, noise, 10 % missing."""
    dealias._self_test()


def test_unaliased_field_is_unchanged():
    true = _wind_sweep() - 12.0  # stays within +-12
    assert np.array_equal(dealias.dealias_sweep(true, VN), true)


def test_sentinels_and_no_nyquist_pass_through():
    vel = _alias(_wind_sweep())
    vel[5:9, :] = -1000.0
    vel[20, 30:40] = -2000.0
    out = dealias.dealias_sweep(vel, VN)
    assert (out[5:9] == -1000.0).all() and (out[20, 30:40] == -2000.0).all()
    assert np.array_equal(dealias.dealias_sweep(vel, 0.0), vel)
    assert np.array_equal(dealias.dealias_sweep(vel, None), vel)


def test_connected_fold_is_unfolded():
    true = _wind_sweep()
    out = dealias.dealias_sweep(_alias(true), VN)
    assert np.abs(out - true).max() < 1e-4


def test_reference_picks_absolute_fold():
    """An isolated echo that is aliased everywhere looks fine on its own; only a reference
    (the tilt below) can tell it is one fold off."""
    true = _wind_sweep()
    patch = np.full_like(true, -1000.0)
    inside = true > 21.0
    patch[inside] = _alias(true)[inside]
    alone = dealias.dealias_sweep(patch, VN)
    assert np.array_equal(alone[inside], patch[inside])
    ref = np.where(inside, true, np.nan)
    fixed = dealias.dealias_sweep(patch, VN, reference=ref)
    assert np.abs(fixed[inside] - true[inside]).max() < 1e-4


def test_volume_references_the_tilt_below():
    true = _wind_sweep()
    upper = np.full_like(true, -1000.0)
    inside = true > 21.0
    upper[inside] = _alias(true)[inside]
    geom = {"nyquist": VN, "first_gate_m": 2125.0, "gate_spacing_m": 250.0}
    sweeps = [  # deliberately out of elevation order; results come back in input order
        dict(geom, vel=upper, elevation_deg=1.5),
        dict(geom, vel=_alias(true), elevation_deg=0.5),
    ]
    up, low = dealias.dealias_volume(sweeps)
    assert np.abs(low - true).max() < 1e-4
    assert np.abs(up[inside] - true[inside]).max() < 1e-4
    assert (up[~inside] == -1000.0).all()


def test_reference_resampling_matches_ground_range():
    below = {"vel": np.arange(10, dtype=np.float32)[None, :].repeat(4, 0), "elevation_deg": 0.0,
             "first_gate_m": 0.0, "gate_spacing_m": 1000.0}
    sw = {"vel": np.zeros((8, 10), np.float32), "elevation_deg": 60.0, "first_gate_m": 0.0, "gate_spacing_m": 1000.0}
    ref = dealias._reference(sw, below)
    assert ref.shape == (8, 10)
    # Slant 4 km at 60 deg is 2 km of ground range -> gate 2 of the flat sweep below.
    assert ref[0, 4] == 2.0
    assert ref[7, 8] == 4.0
    assert np.isnan(dealias._reference(dict(sw, elevation_deg=0.0, first_gate_m=20000.0), below)).all()


def test_components_union_find():
    root = dealias._components(6, np.array([0, 1, 4]), np.array([1, 2, 5]))
    assert root.tolist() == [0, 0, 0, 3, 4, 4]
