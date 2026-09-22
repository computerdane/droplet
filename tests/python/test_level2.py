import datetime as dt
import struct

import numpy as np
import pytest

from nexrad import level2, synth


def _assert_same(decoded: level2.Volume, original: level2.Volume) -> None:
    assert decoded.icao == original.icao
    assert decoded.time == original.time
    assert decoded.latitude == pytest.approx(original.latitude, abs=1e-5)
    assert decoded.longitude == pytest.approx(original.longitude, abs=1e-5)
    assert decoded.height_m == original.height_m
    assert decoded.vcp == original.vcp
    assert len(decoded.radials) == len(original.radials)
    for d, o in zip(decoded.radials, original.radials):
        assert d.azimuth == pytest.approx(o.azimuth, abs=1e-4)
        assert d.elevation == pytest.approx(o.elevation, abs=1e-4)
        assert d.elevation_number == o.elevation_number
        assert d.azimuth_resolution == o.azimuth_resolution
        assert abs((d.time - o.time).total_seconds()) < 1e-3
        assert d.nyquist_ms == pytest.approx(o.nyquist_ms, abs=0.005)
        assert d.unambiguous_range_km == pytest.approx(o.unambiguous_range_km, abs=0.05)
        assert d.moments.keys() == o.moments.keys()
        for name, m in o.moments.items():
            got = d.moments[name]
            assert (got.n_gates, got.first_gate_m, got.gate_spacing_m) == (m.n_gates, m.first_gate_m, m.gate_spacing_m)
            _, scale, _ = synth.ENCODING[name]
            for sentinel in (level2.MISSING, level2.RANGE_FOLDED):
                assert np.array_equal(got.values == sentinel, m.values == sentinel)
            ok = m.values > -900
            if not ok.any():
                continue
            # Within half a quantisation step (plus float32 slack) wherever nothing was clipped.
            assert np.abs(got.values[ok] - m.values[ok]).max() <= 0.5 / scale + 1e-4, name


@pytest.mark.parametrize("layout", ["bz2", "gz"])
def test_round_trip(small_volume, layout):
    raw = synth.encode_archive(small_volume, layout)
    assert raw[:4] == (b"\x1f\x8b\x08\x00" if layout == "gz" else b"AR2V")
    _assert_same(level2.read_volume(raw), small_volume)


def test_sweeps_grouped_in_scan_order(small_volume):
    vol = level2.read_volume(synth.encode_archive(small_volume))
    sweeps = vol.sweeps()
    assert [s[0].elevation_number for s in sweeps] == [1, 2, 3]
    assert [len(s) for s in sweeps] == [720, 720, 360]
    assert set(sweeps[0][0].moments) == {"REF", "ZDR", "PHI", "RHO"}
    assert set(sweeps[1][0].moments) == {"REF", "VEL", "SW"}


def test_sentinels_present(small_volume):
    vol = level2.read_volume(synth.encode_archive(small_volume))
    vel = np.concatenate([r.moments["VEL"].values for r in vol.sweeps()[1]])
    assert (vel == level2.MISSING).any()
    assert (vel == level2.RANGE_FOLDED).any()


def test_read_file(small_volume, tmp_path):
    p = tmp_path / "KTST20240501_220000_V06"
    p.write_bytes(synth.encode_archive(small_volume))
    assert len(level2.read_file(str(p)).radials) == len(small_volume.radials)


def test_partial_archive_decodes_available_radials(small_volume):
    """What live() does: decode header + the first records only."""
    parts = synth.ldm_records(synth.encode_archive(small_volume))
    partial = level2.read_volume(b"".join(parts[:4]))  # header, metadata, 2 radial records
    assert len(partial.radials) == 2 * synth.RADIALS_PER_RECORD
    assert partial.vcp == 212


def test_metadata_only_has_no_radials(small_volume):
    parts = synth.ldm_records(synth.encode_archive(small_volume))
    with pytest.raises(ValueError, match="no Message 31"):
        level2.read_volume(b"".join(parts[:2]))


def test_not_archive2():
    with pytest.raises(ValueError, match="AR2V"):
        level2.read_volume(b"hello world, definitely not radar data")


def test_msg31_overflow_size(small_volume):
    """A Message 31 whose halfword size is 65535 carries its byte length in the segment fields."""
    vol = level2.Volume(
        icao=small_volume.icao,
        time=small_volume.time,
        latitude=small_volume.latitude,
        longitude=small_volume.longitude,
        height_m=small_volume.height_m,
        vcp=small_volume.vcp,
        radials=small_volume.radials[:2],
    )
    msgs = [synth._msg31(vol, r, i + 1) for i, r in enumerate(vol.radials)]
    first = bytearray(msgs[0])
    total = len(first) - level2.CTM_HEADER_SIZE
    c = level2.CTM_HEADER_SIZE
    struct.pack_into(">H", first, c, level2.MSG31_OVERFLOW)
    struct.pack_into(">HH", first, c + 12, total >> 16, total & 0xFFFF)
    raw = synth.volume_header(vol) + b"".join([bytes(first), msgs[1]])
    got = level2.read_volume(raw)  # uncompressed stream, as in the old layout
    assert len(got.radials) == 2
    assert got.radials[1].azimuth == pytest.approx(vol.radials[1].azimuth)


def test_julian_dates():
    assert level2._julian_to_datetime(1, 0) == dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
    t = dt.datetime(2013, 5, 20, 20, 3, 59, 250000, tzinfo=dt.timezone.utc)
    assert level2._julian_to_datetime(*synth._julian(t)) == t


def test_quantise_clips_and_marks_sentinels():
    v = np.array([level2.MISSING, level2.RANGE_FOLDED, -99.0, 0.0, 200.0], dtype=np.float32)
    assert synth.quantise("REF", v).tolist() == [0, 1, 2, 66, 255]
    assert synth.quantise("PHI", np.array([360.0], dtype=np.float32)).dtype == np.dtype(">u2")
