import numpy as np
import pytest

from nexrad import vad


def test_synthetic_profile_and_bunkers():
    """The module self-test: veering profile from aliased, noisy sweeps with a mis-dealiased blob."""
    vad._self_test()


def test_beam_height():
    r = np.array([10_000.0])
    assert vad.beam_height_m(r, 0.0)[0] == pytest.approx(r[0] ** 2 / (2 * vad.EARTH_RADIUS_M), rel=1e-3)
    assert vad.beam_height_m(r, 90.0)[0] == pytest.approx(10_000.0, abs=0.01)


def _uniform_sweep(u: float, v: float, elev: float, n_az: int = 360, n_g: int = 240) -> dict:
    az = np.radians((np.arange(n_az) + 0.5) * 360.0 / n_az)[:, None]
    vr = np.cos(np.radians(elev)) * (u * np.sin(az) + v * np.cos(az)) + np.zeros((1, n_g))
    return {"dvel": vr, "vel": vr.copy(), "nyquist": 30.0, "elevation_deg": elev,
            "first_gate_m": 2125.0, "gate_spacing_m": 250.0}


def test_fit_rings_recovers_uniform_wind():
    sw = _uniform_sweep(7.0, -4.0, 2.4)
    fits = vad.fit_rings(sw["dvel"], sw["vel"], sw["nyquist"], sw["elevation_deg"], sw["first_gate_m"], sw["gate_spacing_m"])
    assert fits
    for h, u, v, rms in fits:
        assert (u, v) == (pytest.approx(7.0, abs=1e-6), pytest.approx(-4.0, abs=1e-6))
        assert rms < 1e-6
    heights = [f[0] for f in fits]
    assert heights == sorted(heights)


def test_fit_rings_rejects_steep_and_gappy_sweeps():
    steep = _uniform_sweep(5.0, 5.0, 25.0)
    assert vad.fit_rings(steep["dvel"], None, 30.0, 25.0, 2125.0, 250.0) == []
    gappy = _uniform_sweep(5.0, 5.0, 1.0)
    gappy["dvel"][:90] = -1000.0  # a whole 90 degree quadrant missing
    assert vad.fit_rings(gappy["dvel"], None, 30.0, 1.0, 2125.0, 250.0) == []


def test_wind_profile_none_without_data():
    sw = _uniform_sweep(5.0, 5.0, 1.0)
    sw["dvel"][:] = -1000.0
    assert vad.wind_profile([sw]) is None


def test_bunkers_straight_hodograph():
    h = np.arange(125.0, 6200.0, 250.0)
    prof = {"height_m": h.tolist(), "u_ms": (h / 6000.0 * 20.0).tolist(), "v_ms": [0.0] * len(h)}
    bk = vad.bunkers(prof)
    mean_u = np.interp(np.arange(0, 6001, 250.0), h, h / 6000.0 * 20.0).mean()
    assert bk["mean_0_6km"] == pytest.approx([mean_u, 0.0], abs=0.01)
    assert bk["shear_0_6km"][1] == pytest.approx(0.0, abs=0.01)
    # Right mover: 7.5 m/s to the right of the (eastward) shear, i.e. south of the mean wind.
    assert bk["right"] == pytest.approx([mean_u, -7.5], abs=0.01)
    assert bk["left"] == pytest.approx([mean_u, 7.5], abs=0.01)
    assert bk["srh_0_3km"] > bk["srh_0_1km"] > 0


def test_bunkers_needs_deep_profile():
    assert vad.bunkers(None) is None
    shallow = {"height_m": [250.0, 1500.0, 3000.0], "u_ms": [1.0, 5.0, 9.0], "v_ms": [0.0, 2.0, 4.0]}
    assert vad.bunkers(shallow) is None
    elevated = {"height_m": [1500.0, 6000.0], "u_ms": [1.0, 9.0], "v_ms": [0.0, 4.0]}
    assert vad.bunkers(elevated) is None
