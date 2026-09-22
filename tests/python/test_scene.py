"""End-to-end accuracy on the synthetic storm: the scene is known, so DVEL and the VAD
profile can be scored against the truth rather than eyeballed."""

import dataclasses

import numpy as np
import pytest

from nexrad import dealias, synth, vad


def _vel_sweeps(scene: synth.Scene) -> list[dict]:
    vol = scene.volume(synth.FIXTURE_SITES[0], synth.T0)
    out = []
    for radials in vol.sweeps():
        if "VEL" in radials[0].moments:
            m = radials[0].moments["VEL"]
            out.append(
                {
                    "vel": np.stack([r.moments["VEL"].values for r in radials]),
                    "nyquist": scene.nyquist_ms,
                    "elevation_deg": float(np.mean([r.elevation for r in radials])),
                    "first_gate_m": m.first_gate_m,
                    "gate_spacing_m": m.gate_spacing_m,
                }
            )
    return out


@pytest.fixture(scope="module")
def truth():
    # Same random draws, but a Nyquist so large that nothing aliases.
    return _vel_sweeps(dataclasses.replace(synth.fixture_scene(), nyquist_ms=1e4))


@pytest.mark.parametrize("nyquist", [20.0, 15.0, 12.0])
def test_dealias_recovers_truth(truth, nyquist):
    sweeps = _vel_sweeps(dataclasses.replace(synth.fixture_scene(), nyquist_ms=nyquist))
    aliased = wrong = total = 0
    for sw, out, t in zip(sweeps, dealias.dealias_volume(sweeps), truth):
        ok = sw["vel"] > -900
        aliased += (np.abs(sw["vel"] - t["vel"])[ok] > 1.0).sum()
        wrong += (np.abs(out - t["vel"])[ok] > 1.0).sum()
        total += ok.sum()
    assert aliased / total > 0.05  # the test means something
    assert wrong / total < 1e-3


def test_vad_matches_scene_wind():
    # Without the couplet: a vortex is not the uniform wind VAD assumes, and biases it by ~2 m/s.
    scene = dataclasses.replace(synth.fixture_scene(), couplet_ms=0.0)
    unaliased = _vel_sweeps(dataclasses.replace(scene, nyquist_ms=1e4))
    sweeps = [dict(sw, dvel=sw["vel"], nyquist=scene.nyquist_ms) for sw in unaliased]
    prof = vad.wind_profile(sweeps)
    assert prof is not None
    h = np.array(prof["height_m"])
    assert h.min() <= 1000 and h.max() >= 5000
    u, v = scene.wind(h)
    err = np.hypot(np.array(prof["u_ms"]) - u, np.array(prof["v_ms"]) - v)
    assert err.max() < 1.0, list(zip(h, err))
    assert vad.bunkers(prof) is not None
