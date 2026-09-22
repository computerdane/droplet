"""Minimal NEXRAD Level II (Archive2, Message 31) decoder.

Only depends on numpy and the stdlib. Handles the modern Build 12+ format:
a 24-byte volume header followed by bzip2-compressed LDM records containing
metadata messages (fixed 2432 bytes) and Message 31 radials (variable size).

Reference: NWS ICD 2620010 (RDA/RPG Interface Control Document).
"""

from __future__ import annotations

import bz2
import datetime as dt
import gzip
import struct
from dataclasses import dataclass, field

import numpy as np

CTM_HEADER_SIZE = 12
MSG_HEADER_SIZE = 16
FIXED_MSG_SIZE = 2432  # CTM + header + 2404 bytes of data for non-31 messages
MSG31_OVERFLOW = 65535

# Sentinels stored in output arrays (float16-exact).
MISSING = -1000.0
RANGE_FOLDED = -2000.0


@dataclass
class Moment:
    name: str
    n_gates: int
    first_gate_m: int  # range to center of first gate, meters
    gate_spacing_m: int
    values: np.ndarray  # float32, MISSING / RANGE_FOLDED sentinels


@dataclass
class Radial:
    azimuth: float
    elevation: float
    elevation_number: int
    azimuth_resolution: int  # 1 = 0.5 deg, 2 = 1.0 deg
    time: dt.datetime
    nyquist_ms: float | None
    unambiguous_range_km: float | None
    moments: dict[str, Moment] = field(default_factory=dict)


@dataclass
class Volume:
    icao: str
    time: dt.datetime
    latitude: float | None = None
    longitude: float | None = None
    height_m: float | None = None
    vcp: int | None = None
    radials: list[Radial] = field(default_factory=list)
    complete: bool = True

    def sweeps(self) -> list[list[Radial]]:
        """Group radials by elevation number, in scan order."""
        groups: dict[int, list[Radial]] = {}
        for r in self.radials:
            groups.setdefault(r.elevation_number, []).append(r)
        return [groups[k] for k in sorted(groups)]


def _julian_to_datetime(days: int, ms: int) -> dt.datetime:
    # NEXRAD "modified Julian date": days since 1 Jan 1970, where 1 == 1970-01-01.
    base = dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)
    return base + dt.timedelta(days=days - 1, milliseconds=ms)


def _iter_records(raw: bytes):
    """Yield decompressed LDM records following the 24-byte volume header.

    Older archives (roughly pre-2016, distributed as .gz) hold the message stream
    uncompressed right after the header instead of in bzip2 LDM records.
    """
    if raw[28:31] != b"BZh":
        yield raw[24:]
        return
    pos = 24
    while pos + 4 <= len(raw):
        (size,) = struct.unpack(">i", raw[pos : pos + 4])
        pos += 4
        size = abs(size)
        if size == 0:
            break
        chunk = raw[pos : pos + size]
        pos += size
        if not chunk:
            break
        yield bz2.decompress(chunk)


def _parse_msg31(data: bytes, volume: Volume) -> Radial:
    (
        ms,
        jdate,
        _az_num,
        az,
        _compression,
        _spare,
        _radial_len,
        az_res,
        _status,
        elev_num,
        _sector,
        elev,
        _spot_blank,
        _az_mode,
        n_blocks,
    ) = struct.unpack(">IHHfBBHBBBBfBBH", data[4:32])
    pointers = struct.unpack(f">{n_blocks}I", data[32 : 32 + 4 * n_blocks])

    radial = Radial(
        azimuth=az,
        elevation=elev,
        elevation_number=elev_num,
        azimuth_resolution=az_res,
        time=_julian_to_datetime(jdate, ms),
        nyquist_ms=None,
        unambiguous_range_km=None,
    )

    for p in pointers:
        if p == 0 or p + 4 > len(data):
            continue
        btype = chr(data[p])
        name = data[p + 1 : p + 4].decode("ascii", "replace").strip()

        if btype == "R" and name == "VOL":
            lat, lon = struct.unpack(">ff", data[p + 8 : p + 16])
            (height,) = struct.unpack(">h", data[p + 16 : p + 18])
            (vcp,) = struct.unpack(">H", data[p + 40 : p + 42])
            volume.latitude, volume.longitude = lat, lon
            volume.height_m, volume.vcp = float(height), vcp
        elif btype == "R" and name == "RAD":
            (unamb,) = struct.unpack(">H", data[p + 6 : p + 8])
            (nyq,) = struct.unpack(">h", data[p + 16 : p + 18])
            radial.unambiguous_range_km = unamb * 0.1
            radial.nyquist_ms = nyq * 0.01
        elif btype == "D":
            (
                n_gates,
                first_gate,
                spacing,
                _tover,
                _snr,
                _ctrl,
                word_bits,
                scale,
                offset,
            ) = struct.unpack(">HhHHhBBff", data[p + 8 : p + 28])
            dtype = ">u1" if word_bits == 8 else ">u2"
            raw = np.frombuffer(data, dtype=dtype, count=n_gates, offset=p + 28)
            vals = (raw.astype(np.float32) - offset) / scale
            vals[raw == 0] = MISSING
            vals[raw == 1] = RANGE_FOLDED
            radial.moments[name] = Moment(name, n_gates, first_gate, spacing, vals)

    return radial


def read_volume(raw: bytes) -> Volume:
    if raw[:2] == b"\x1f\x8b":  # older archive files (pre ~2016) are gzip-wrapped
        raw = gzip.decompress(raw)
    if raw[:6] != b"AR2V00":
        raise ValueError("not an Archive2 volume (missing AR2V header)")
    (vol_date, vol_ms) = struct.unpack(">II", raw[12:20])
    icao = raw[20:24].decode("ascii", "replace")
    volume = Volume(icao=icao, time=_julian_to_datetime(vol_date, vol_ms))

    for rec in _iter_records(raw):
        pos = 0
        while pos + CTM_HEADER_SIZE + MSG_HEADER_SIZE <= len(rec):
            hdr = rec[pos + CTM_HEADER_SIZE : pos + CTM_HEADER_SIZE + MSG_HEADER_SIZE]
            size_hw, _chan, mtype, _seq, _jd, _ms, n_seg, seg_num = struct.unpack(
                ">HBBHHIHH", hdr
            )
            if mtype == 31:
                if size_hw == MSG31_OVERFLOW:
                    total = (n_seg << 16) | seg_num
                else:
                    total = size_hw * 2
                start = pos + CTM_HEADER_SIZE + MSG_HEADER_SIZE
                end = pos + CTM_HEADER_SIZE + total
                volume.radials.append(_parse_msg31(rec[start:end], volume))
                pos = end
            else:
                # Fixed-size message, or an empty (type 0) padding slot in the metadata block.
                pos += FIXED_MSG_SIZE

    if not volume.radials:
        raise ValueError("no Message 31 radials found")
    return volume


def read_file(path: str) -> Volume:
    with open(path, "rb") as f:
        return read_volume(f.read())
