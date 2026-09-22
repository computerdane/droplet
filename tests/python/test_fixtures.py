"""The synthetic fixture volumes (python -m nexrad.synth) carry what the Godot tests need."""

import json

import numpy as np

from nexrad import synth


def _meta(root, name):
    return json.loads((root / name / "volume.json").read_text())


def test_fixture_set(fixture_root):
    names = sorted(p.name for p in fixture_root.iterdir())
    assert names == ["KTST_20240501_220000", "KTST_20240501_220500", "KTSU_20240501_220210"]


def test_split_cut_and_sails_repeat(fixture_root):
    sweeps = _meta(fixture_root, "KTST_20240501_220000")["sweeps"]
    low = [s for s in sweeps if abs(s["elevation_deg"] - 0.5) < 0.1]
    assert len(low) == 3  # surveillance + Doppler cut, and the SAILS repeat at the end
    assert "VEL" not in low[0]["fields"] and "VEL" in low[1]["fields"] and "VEL" in low[2]["fields"]
    assert low[2]["time"] > low[1]["time"]
    assert {s["azimuth_step_deg"] for s in sweeps} == {0.5, 1.0}
    assert len({round(s["elevation_deg"], 1) for s in sweeps}) == 6


def test_storm_and_sentinels(fixture_root):
    root = fixture_root / "KTST_20240501_220000"
    meta = _meta(fixture_root, root.name)
    s = meta["sweeps"][1]
    ref = np.fromfile(root / s["fields"]["REF"]["file"], dtype="<f2")
    vel = np.fromfile(root / s["fields"]["VEL"]["file"], dtype="<f2")
    assert ref.max() > 50  # the core
    assert (vel == -1000).any() and (vel == -2000).any()
    top = meta["sweeps"][6]
    assert (np.fromfile(root / top["fields"]["REF"]["file"], dtype="<f2") == -1000).any()  # clear air aloft
    assert meta["storm_motion"]["method"] == "bunkers"
    # The neighbour has two tilts and too shallow a profile for Bunkers.
    assert _meta(fixture_root, "KTSU_20240501_220210")["storm_motion"] is None


def test_storm_moves_between_volumes(fixture_root):
    def core_bin(name):
        root = fixture_root / name
        s = _meta(fixture_root, name)["sweeps"][1]
        f = s["fields"]["REF"]
        ref = np.fromfile(root / f["file"], dtype="<f2").reshape(s["n_azimuth_bins"], f["n_gates"])
        return np.unravel_index(np.argmax(np.where(ref > -900, ref, -99)), ref.shape)

    a, b = core_bin("KTST_20240501_220000"), core_bin("KTST_20240501_220500")
    assert a != b


def test_deterministic(fixture_root, tmp_path):
    again = synth.build_fixtures(tmp_path / "volumes")
    for p in again:
        for f in p.iterdir():
            assert f.read_bytes() == (fixture_root / p.name / f.name).read_bytes(), f"{p.name}/{f.name}"
