import datetime as dt
import json

import numpy as np
import pytest

from nexrad import __main__ as cli
from nexrad import level2, synth

from fakes import FakeResponse, s3_listing

UTC = dt.timezone.utc


def test_parse_and_key_time():
    assert cli.parse_time("2013-05-20T20:00Z") == dt.datetime(2013, 5, 20, 20, tzinfo=UTC)
    assert cli.parse_time(" 2013-05-20T20:00 ").tzinfo == UTC
    assert cli.key_time("2013/05/20/KTLX/KTLX20130520_200359_V06.gz") == dt.datetime(2013, 5, 20, 20, 3, 59, tzinfo=UTC)
    assert cli.key_time("2013/05/20/KTLX/NOP3_20130520") is None


@pytest.fixture
def bucket(monkeypatch):
    """Archive bucket listings from a dict of day -> file names, via a fake requests.get."""
    days: dict[str, list[str]] = {}

    def get(url, params, timeout):
        return FakeResponse(s3_listing([params["prefix"] + name for name in days.get(params["prefix"], [])]))

    monkeypatch.setattr(cli.requests, "get", get)

    def put(day: str, *names: str):
        days[f"{day}/KTST/"] = list(names)

    return put


def test_list_keys_filters_and_sorts(bucket):
    bucket("2024/05/01", "KTST20240501_220500_V06", "KTST20240501_220000_V06", "KTST20240501_220000_V06_MDM", "junk")
    keys = cli.list_keys("ktst", dt.date(2024, 5, 1))
    assert keys == ["2024/05/01/KTST/KTST20240501_220000_V06", "2024/05/01/KTST/KTST20240501_220500_V06"]


def test_key_at_and_between(bucket):
    bucket("2024/04/30", "KTST20240430_235500_V06")
    bucket("2024/05/01", "KTST20240501_000400_V06", "KTST20240501_001000_V06")
    at = cli.key_at("KTST", dt.datetime(2024, 5, 1, 0, 2, tzinfo=UTC))
    assert at.endswith("KTST20240430_235500_V06")  # falls back to the previous day
    assert cli.key_at("KTST", dt.datetime(2024, 5, 1, 0, 5, tzinfo=UTC)).endswith("000400_V06")
    with pytest.raises(SystemExit):
        cli.key_at("KTST", dt.datetime(2024, 4, 30, 12, 0, tzinfo=UTC))
    between = cli.keys_between("KTST", dt.datetime(2024, 4, 30, 23, 0, tzinfo=UTC), dt.datetime(2024, 5, 1, 0, 5, tzinfo=UTC))
    assert [k.rsplit("/", 1)[1] for k in between] == ["KTST20240430_235500_V06", "KTST20240501_000400_V06"]


def test_resolve_keys_needs_both_ends():
    args = type("A", (), {"site": "KTST", "at": None, "start": "2024-05-01T00:00Z", "end": None})
    with pytest.raises(SystemExit, match="--from and --to"):
        cli.resolve_keys(args)


@pytest.fixture(scope="module")
def written(small_volume, tmp_path_factory):
    vol = level2.read_volume(synth.encode_archive(small_volume))
    return vol, cli.write_volume(vol, tmp_path_factory.mktemp("volumes"))


def test_write_volume_layout(written):
    vol, out = written
    assert out.name == "KTST_20240501_220000"
    meta = json.loads((out / "volume.json").read_text())
    assert meta["format_version"] == 1
    assert (meta["icao"], meta["vcp"], meta["complete"]) == ("KTST", 212, True)
    assert meta["time"] == "2024-05-01T22:00:00+00:00"
    assert (meta["missing"], meta["range_folded"], meta["dtype"]) == (-1000.0, -2000.0, "float16-le")
    assert [s["index"] for s in meta["sweeps"]] == [0, 1, 2]
    assert [s["azimuth_step_deg"] for s in meta["sweeps"]] == [0.5, 0.5, 1.0]
    assert [s["n_azimuth_bins"] for s in meta["sweeps"]] == [720, 720, 360]
    assert set(meta["sweeps"][1]["fields"]) == {"REF", "VEL", "SW", "DVEL"}
    assert not list(out.glob("*.tmp"))
    files = {p.name for p in out.iterdir()}
    for sw in meta["sweeps"]:
        assert sw["nyquist_ms"] == pytest.approx(20.0)
        for name, f in sw["fields"].items():
            assert f["file"] == f"s{sw['index']:02d}_{name}.bin" and f["file"] in files
            assert (out / f["file"]).stat().st_size == sw["n_azimuth_bins"] * f["n_gates"] * 2
        if "VEL" in sw["fields"]:
            vel, dvel = sw["fields"]["VEL"], sw["fields"]["DVEL"]
            assert {k: v for k, v in vel.items() if k != "file"} == {k: v for k, v in dvel.items() if k != "file"}
    assert set(files) == {f["file"] for sw in meta["sweeps"] for f in sw["fields"].values()} | {"volume.json"}


def test_write_volume_values(written):
    """Each radial lands in bin floor(azimuth / step), as float16, sentinels kept exact."""
    vol, out = written
    meta = json.loads((out / "volume.json").read_text())
    for sw, radials in zip(meta["sweeps"], vol.sweeps()):
        step = sw["azimuth_step_deg"]
        for name, f in sw["fields"].items():
            if name == "DVEL":
                continue
            grid = np.fromfile(out / f["file"], dtype="<f2").reshape(sw["n_azimuth_bins"], f["n_gates"])
            for r in radials[::37]:
                want = r.moments[name].values.astype(np.float16)
                assert np.array_equal(grid[int(r.azimuth / step)], want), (sw["index"], name, r.azimuth)
            assert set(np.unique(grid[grid < -900])) <= {np.float16(-1000.0), np.float16(-2000.0)}


def test_dealiased_and_winds(written):
    vol, out = written
    meta = json.loads((out / "volume.json").read_text())
    sw = meta["sweeps"][2]
    shape = (sw["n_azimuth_bins"], sw["fields"]["VEL"]["n_gates"])
    vel = np.fromfile(out / sw["fields"]["VEL"]["file"], dtype="<f2").reshape(shape)
    dvel = np.fromfile(out / sw["fields"]["DVEL"]["file"], dtype="<f2").reshape(shape)
    assert np.array_equal(vel < -900, dvel < -900)
    ok = vel > -900
    folds = (dvel[ok].astype(np.float32) - vel[ok]) / (2 * sw["nyquist_ms"])
    assert np.allclose(folds, np.round(folds), atol=0.01)  # DVEL = VEL + whole folds
    assert np.abs(dvel[ok]).max() > sw["nyquist_ms"]  # the scene aliases; something was unfolded
    assert meta["wind_profile"] is not None


def test_add_winds_recomputes(written):
    _, out = written
    meta = json.loads((out / "volume.json").read_text())
    before = meta["wind_profile"], meta["storm_motion"]
    meta["wind_profile"] = meta["storm_motion"] = None
    cli.write_meta(out, meta)
    cli.add_winds(out)
    after = json.loads((out / "volume.json").read_text())
    assert (after["wind_profile"], after["storm_motion"]) == before


def test_main_decode_and_winds(monkeypatch, tmp_path, small_volume, capsys):
    raw = tmp_path / "KTST20240501_220000_V06.gz"
    raw.write_bytes(synth.encode_archive(small_volume, "gz"))
    monkeypatch.setattr(cli, "VOLUMES_DIR", tmp_path / "volumes")
    cli.main(["decode", str(raw)])
    out = capsys.readouterr().out.strip()
    assert out.endswith("KTST_20240501_220000")
    cli.main(["winds", out])
    assert capsys.readouterr().out.startswith("KTST_20240501_220000: ")
