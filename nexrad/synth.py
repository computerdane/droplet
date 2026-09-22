"""Synthetic NEXRAD data for tests: an Archive2 encoder and a small, deterministic storm scene.

`encode_archive()` is the inverse of level2.read_volume(): it writes a level2.Volume as an
Archive2 file in either layout the decoder reads (bzip2 LDM records, or the older
gzip-wrapped uncompressed stream), with a metadata record of fixed-size messages in front
like the real files. Values are quantised with the usual per-moment scale/offset, so a
round trip is exact to within half a quantisation step.

`Scene` renders one storm (a reflectivity core with a rotation couplet, drifting with the
storm motion) in a veering, strengthening environmental wind, as seen by any radar at any
time. Sites share the scene's geometry, so neighbouring radars see the same storm.

    python -m nexrad.synth [out_dir]    # (re)build tests/fixtures/volumes
"""

from __future__ import annotations

import bz2
import datetime as dt
import gzip
import shutil
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import level2, vad

# Moment encodings as the RDA sends them: (word bits, scale, offset); raw = value * scale + offset.
ENCODING = {
    "REF": (8, 2.0, 66.0),
    "VEL": (8, 2.0, 129.0),
    "SW": (8, 2.0, 129.0),
    "ZDR": (8, 16.0, 128.0),
    "PHI": (16, 2.8361, 2.0),
    "RHO": (8, 300.0, -60.5),
}
RADIALS_PER_RECORD = 120
FIXTURE_DIR = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "volumes"
KM_PER_DEG = 111.195


def _julian(t: dt.datetime) -> tuple[int, int]:
    """NEXRAD modified Julian date (1 == 1970-01-01) and milliseconds past midnight."""
    days = (t.date() - dt.date(1970, 1, 1)).days + 1
    ms = ((t.hour * 60 + t.minute) * 60 + t.second) * 1000 + t.microsecond // 1000
    return days, ms


def quantise(name: str, values: np.ndarray) -> np.ndarray:
    """Raw gate words for a moment: 0 = below threshold, 1 = range folded."""
    bits, scale, offset = ENCODING[name]
    raw = np.clip(np.round(values * scale + offset), 2, (1 << bits) - 1)
    raw = np.where(values == level2.MISSING, 0, raw)
    raw = np.where(values == level2.RANGE_FOLDED, 1, raw)
    return raw.astype(">u1" if bits == 8 else ">u2")


def _message(mtype: int, body: bytes, t: dt.datetime, seq: int) -> bytes:
    """CTM header + message header + body. Size is in halfwords and excludes the CTM header."""
    if len(body) % 2:
        body += b"\0"
    days, ms = _julian(t)
    size_hw = (level2.MSG_HEADER_SIZE + len(body)) // 2
    hdr = struct.pack(">HBBHHIHH", size_hw, 8, mtype, seq & 0xFFFF, days, ms, 1, 1)
    return bytes(level2.CTM_HEADER_SIZE) + hdr + body


def _fixed_message(mtype: int, t: dt.datetime, seq: int) -> bytes:
    """A metadata message padded to the fixed 2432-byte slot (contents are not decoded)."""
    msg = _message(mtype, b"", t, seq)
    return msg + bytes(level2.FIXED_MSG_SIZE - len(msg))


def _msg31(vol: level2.Volume, r: level2.Radial, az_num: int) -> bytes:
    blocks = [
        b"RVOL"
        + struct.pack(
            ">HBBffhHfffffHH",
            44,
            1,
            0,
            vol.latitude,
            vol.longitude,
            int(vol.height_m),
            10,
            0.0,
            0.0,
            0.0,
            0.0,
            0.0,
            vol.vcp,
            0,
        ),
        b"RELV" + struct.pack(">Hhf", 12, 0, 0.0),
        b"RRAD"
        + struct.pack(
            ">HHffhhff", 28, int(round(r.unambiguous_range_km * 10)), 0.0, 0.0, int(round(r.nyquist_ms * 100)), 0, 0.0, 0.0
        ),
    ]
    for name, m in r.moments.items():
        bits, scale, offset = ENCODING[name]
        data = quantise(name, m.values).tobytes()
        blk = b"D" + name.ljust(3).encode() + struct.pack(
            ">IHhHHhBBff", 0, m.n_gates, m.first_gate_m, m.gate_spacing_m, 0, 0, 0, bits, scale, offset
        )
        blk += data + b"\0" * (len(data) % 2)
        blocks.append(blk)

    head = 32 + 4 * len(blocks)
    pointers, pos = [], head
    for b in blocks:
        pointers.append(pos)
        pos += len(b)
    days, ms = _julian(r.time)
    body = vol.icao.encode()[:4].ljust(4) + struct.pack(
        ">IHHfBBHBBBBfBBH",
        ms,
        days,
        az_num,
        r.azimuth,
        0,
        0,
        pos,
        r.azimuth_resolution,
        0,
        r.elevation_number,
        0,
        r.elevation,
        0,
        0,
        len(blocks),
    )
    body += struct.pack(f">{len(blocks)}I", *pointers) + b"".join(blocks)
    return _message(31, body, r.time, az_num)


def _records(vol: level2.Volume) -> list[bytes]:
    """Uncompressed LDM record payloads: one metadata record, then radials in batches."""
    meta = b"".join(_fixed_message(t, vol.time, i) for i, t in enumerate((15, 13, 18, 3, 5, 2, 0)))
    out = [meta]
    for i in range(0, len(vol.radials), RADIALS_PER_RECORD):
        batch = vol.radials[i : i + RADIALS_PER_RECORD]
        out.append(b"".join(_msg31(vol, r, i + k + 1) for k, r in enumerate(batch)))
    return out


def volume_header(vol: level2.Volume) -> bytes:
    days, ms = _julian(vol.time)
    return b"AR2V0006." + b"001" + struct.pack(">II", days, ms) + vol.icao.encode()[:4].ljust(4)


def encode_archive(vol: level2.Volume, layout: str = "bz2") -> bytes:
    """Archive2 bytes for `vol`. layout "bz2": header + bzip2 LDM records, each prefixed by
    its signed length (the last one negative, as some writers do); "gz": the whole file
    gzip-wrapped with the message stream uncompressed after the header (pre-2016 layout)."""
    records = _records(vol)
    if layout == "gz":
        return gzip.compress(volume_header(vol) + b"".join(records), mtime=0)
    if layout != "bz2":
        raise ValueError(f"unknown layout {layout!r}")
    out = bytearray(volume_header(vol))
    for i, rec in enumerate(records):
        c = bz2.compress(rec)
        out += struct.pack(">i", -len(c) if i == len(records) - 1 else len(c)) + c
    return bytes(out)


def ldm_records(archive: bytes) -> list[bytes]:
    """Split a bz2-layout archive into [header, record, record, ...] byte strings, each record
    with its length prefix, like the chunks bucket serves them (the S chunk = header + first)."""
    out, pos = [archive[:24]], 24
    while pos + 4 <= len(archive):
        (size,) = struct.unpack(">i", archive[pos : pos + 4])
        out.append(archive[pos : pos + 4 + abs(size)])
        pos += 4 + abs(size)
    return out


# --- scene --------------------------------------------------------------------------------


@dataclass
class Site:
    icao: str
    latitude: float
    longitude: float
    height_m: float = 370.0


@dataclass
class Tilt:
    """One sweep of the scan: elevation, azimuth step (0.5 or 1.0) and the moments it carries."""

    elevation: float
    step: float
    moments: tuple[str, ...]


DOPPLER = ("REF", "VEL", "SW")
SURVEILLANCE = ("REF", "ZDR", "PHI", "RHO")
ALL = ("REF", "VEL", "SW", "ZDR", "PHI", "RHO")
# A cut-down VCP 212: split cut at 0.5 deg, a SAILS repeat of it at the end, batch cuts above.
SCAN = (
    Tilt(0.5, 0.5, SURVEILLANCE),
    Tilt(0.5, 0.5, DOPPLER),
    Tilt(1.5, 1.0, ALL),
    Tilt(3.0, 1.0, DOPPLER),
    Tilt(5.0, 1.0, DOPPLER),
    Tilt(7.5, 1.0, DOPPLER),
    Tilt(11.0, 1.0, DOPPLER),
    Tilt(0.5, 0.5, DOPPLER),
)


@dataclass
class Scene:
    """One supercell-ish storm near `origin`, drifting with `storm_motion` (m/s east, north)
    from `center_km` (east, north of origin) at `t0`, in a wind veering from 10 m/s southerly
    at the ground to 30 m/s westerly at 6 km."""

    origin: tuple[float, float]
    t0: dt.datetime
    center_km: tuple[float, float] = (18.0, 14.0)
    storm_motion: tuple[float, float] = (10.0, 6.0)
    core_dbz: float = 58.0
    core_radius_km: float = 7.0
    couplet_ms: float = 25.0
    nyquist_ms: float = 20.0
    ref_gates: tuple[int, int, int] = (48, 1000, 1000)  # n, first gate, spacing (m)
    dop_gates: tuple[int, int, int] = (48, 1000, 1000)
    seed: int = 0

    def wind(self, height_m: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        f = np.clip(height_m / 6000.0, 0.0, 1.5)
        spd = 10.0 + 20.0 * f
        frm = np.radians(180.0 + 90.0 * f)  # direction the wind blows from
        return -spd * np.sin(frm), -spd * np.cos(frm)

    def site_offset_km(self, site: Site) -> tuple[float, float]:
        lat0, lon0 = self.origin
        return (
            (site.longitude - lon0) * KM_PER_DEG * np.cos(np.radians(lat0)),
            (site.latitude - lat0) * KM_PER_DEG,
        )

    def volume(self, site: Site, time: dt.datetime, scan: tuple[Tilt, ...] = SCAN) -> level2.Volume:
        rng = np.random.default_rng([self.seed, int(time.timestamp()), sum(map(ord, site.icao))])
        vol = level2.Volume(
            icao=site.icao,
            time=time,
            latitude=site.latitude,
            longitude=site.longitude,
            height_m=site.height_m,
            vcp=212,
        )
        ox, oy = self.site_offset_km(site)
        elapsed = (time - self.t0).total_seconds()
        cx = self.center_km[0] + self.storm_motion[0] * elapsed / 1000.0 - ox
        cy = self.center_km[1] + self.storm_motion[1] * elapsed / 1000.0 - oy
        t = time
        for num, tilt in enumerate(scan, start=1):
            n_az = int(round(360.0 / tilt.step))
            az = (np.arange(n_az) + 0.5) * tilt.step
            fields = self._sweep(tilt, az, cx, cy, rng)
            for i in range(n_az):
                vol.radials.append(
                    level2.Radial(
                        azimuth=float(az[i]),
                        elevation=tilt.elevation + float(rng.normal(0.0, 0.02)),
                        elevation_number=num,
                        azimuth_resolution=1 if tilt.step == 0.5 else 2,
                        time=t + dt.timedelta(seconds=15.0 * i / n_az),
                        nyquist_ms=self.nyquist_ms,
                        unambiguous_range_km=466.0 if tilt.moments == SURVEILLANCE else 137.0,
                        moments={
                            name: level2.Moment(name, len(v[i]), first, spacing, v[i])
                            for name, (v, first, spacing) in fields.items()
                        },
                    )
                )
            t += dt.timedelta(seconds=18)
        return vol

    def _sweep(self, tilt: Tilt, az_deg: np.ndarray, cx: float, cy: float, rng) -> dict:
        """Every moment of one sweep: name -> ([az][gate] float32 values with sentinels, first, spacing)."""
        out = {}
        az = np.radians(az_deg)[:, None]
        e = np.radians(tilt.elevation)
        for name in tilt.moments:
            n, first, spacing = self.ref_gates if name in SURVEILLANCE else self.dop_gates
            slant = first + spacing * np.arange(n)[None, :]
            h = vad.beam_height_m(slant, tilt.elevation)
            ground = slant * np.cos(e) / 1000.0
            x, y = ground * np.sin(az), ground * np.cos(az)
            d = np.hypot(x - cx, y - cy)
            core = np.exp(-((d / self.core_radius_km) ** 2)) * np.clip(1.2 - h / 12000.0, 0.0, 1.0)
            ref = 5.0 + (self.core_dbz - 5.0) * core + 10.0 * np.exp(-((d / 25.0) ** 2))
            ref = ref + rng.normal(0.0, 1.0, ref.shape)
            precip = ref > 12.0
            if name == "REF":
                v = np.where(precip | (h < 2500.0), ref, level2.MISSING)
            elif name == "VEL":
                u, w = self.wind(h)
                # Rotation couplet: solid-body inside 2 km of the core centre, 1/r outside.
                vt = self.couplet_ms * np.where(d < 2.0, d / 2.0, 2.0 / np.maximum(d, 1e-6))
                vt *= np.exp(-h / 6000.0)
                ux = u + vt * -(y - cy) / np.maximum(d, 1e-6)
                uy = w + vt * (x - cx) / np.maximum(d, 1e-6)
                true = np.cos(e) * (ux * np.sin(az) + uy * np.cos(az)) + rng.normal(0.0, 1.0, d.shape)
                vn = self.nyquist_ms
                v = (true + vn) % (2.0 * vn) - vn
                v = np.where(rng.random(v.shape) < 0.08, level2.MISSING, v)
                if tilt.elevation < 1.0:  # second-trip echo over a small sector at far range
                    v[(az_deg[:, None] > 300.0) & (az_deg[:, None] < 315.0) & (slant > 35000.0)] = level2.RANGE_FOLDED
            elif name == "SW":
                v = np.where(precip, 1.5 + 4.0 * np.exp(-((d / 2.0) ** 2)), level2.MISSING)
            elif name == "ZDR":
                v = np.where(precip, np.clip(0.2 + (ref - 20.0) / 12.0, -1.0, 4.0), level2.MISSING)
            elif name == "RHO":
                debris = np.exp(-((d / 1.5) ** 2)) * (tilt.elevation < 2.0)
                v = np.where(precip, 0.985 - 0.25 * debris - 0.004 * np.abs(rng.normal(size=d.shape)), level2.MISSING)
            elif name == "PHI":
                rain = np.clip(ref - 30.0, 0.0, None) * 0.05
                v = np.where(precip, 40.0 + np.cumsum(rain, axis=1) * spacing / 1000.0, level2.MISSING)
            out[name] = (v.astype(np.float32), first, spacing)
        return out


# --- fixtures -----------------------------------------------------------------------------

T0 = dt.datetime(2024, 5, 1, 22, 0, 0, tzinfo=dt.timezone.utc)
FIXTURE_SITES = (
    Site("KTST", 35.3331, -97.2778, 370.0),
    Site("KTSU", 35.35, -96.62, 330.0),  # ~60 km east: a mosaic neighbour
)
# (site index, seconds after T0, scan). The neighbour carries two tilts only, to stay small.
FIXTURE_VOLUMES = (
    (0, 0, SCAN),
    (0, 300, SCAN),
    (1, 130, (Tilt(0.5, 0.5, DOPPLER), Tilt(1.5, 1.0, DOPPLER))),
)


def fixture_scene() -> Scene:
    return Scene(origin=(FIXTURE_SITES[0].latitude, FIXTURE_SITES[0].longitude), t0=T0)


def fixture_volumes() -> list[level2.Volume]:
    """The decoded volumes behind tests/fixtures/volumes: each one is encoded to Archive2
    and decoded again, so the fixtures are exactly what the real pipeline would produce."""
    scene = fixture_scene()
    out = []
    for i, (site, secs, scan) in enumerate(FIXTURE_VOLUMES):
        vol = scene.volume(FIXTURE_SITES[site], T0 + dt.timedelta(seconds=secs), scan)
        out.append(level2.read_volume(encode_archive(vol, "gz" if i == 1 else "bz2")))
    return out


def build_fixtures(root: Path = FIXTURE_DIR) -> list[Path]:
    from .__main__ import write_volume

    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    return [write_volume(v, root) for v in fixture_volumes()]


if __name__ == "__main__":
    for p in build_fixtures(Path(sys.argv[1]) if len(sys.argv) > 1 else FIXTURE_DIR):
        print(p)
