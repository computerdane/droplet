"""CLI: python -m nexrad <command> ...

History (archive mirror, ~5 min behind real time, back to ~2008):
    python -m nexrad latest KTLX                          # newest key on the mirror
    python -m nexrad fetch KTLX                           # newest volume -> data/raw/
    python -m nexrad fetch KTLX --at 2013-05-20T20:00Z    # nearest volume at/before a time
    python -m nexrad fetch KTLX --from 2013-05-20T19:30Z --to 2013-05-20T21:30Z
    python -m nexrad decode data/raw/KTLX*                # raw -> data/volumes/<ICAO>_<time>/
    python -m nexrad update KTLX [--at ...]               # fetch + decode

Live (chunks bucket, seconds behind real time):
    python -m nexrad live KTLX                            # poll, decode partial volumes as they grow

Basemap (state/county lines and city labels, once):
    python -m nexrad basemap                              # -> data/basemap/
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import requests

from . import basemap, chunks, level2

BUCKET = "https://unidata-nexrad-level2.s3.amazonaws.com"
ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = ROOT / "data" / "raw"
VOLUMES_DIR = ROOT / "data" / "volumes"
BASEMAP_DIR = ROOT / "data" / "basemap"
S3_NS = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
KEY_TIME = re.compile(r"[A-Z]{4}(\d{8})_(\d{6})")


def parse_time(s: str) -> dt.datetime:
    s = s.strip().replace("Z", "+00:00")
    t = dt.datetime.fromisoformat(s)
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def key_time(key: str) -> dt.datetime | None:
    m = KEY_TIME.search(key.rsplit("/", 1)[-1])
    if not m:
        return None
    return dt.datetime.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S").replace(tzinfo=dt.timezone.utc)


def list_keys(site: str, day: dt.date) -> list[str]:
    prefix = f"{day:%Y/%m/%d}/{site.upper()}/"
    resp = requests.get(BUCKET, params={"list-type": "2", "prefix": prefix, "max-keys": "1000"}, timeout=60)
    resp.raise_for_status()
    root = ET.fromstring(resp.text)
    keys = [el.text for el in root.findall("s3:Contents/s3:Key", S3_NS)]
    # _MDM files are metadata-only stubs; skip them.
    return sorted(k for k in keys if k and not k.endswith("_MDM") and key_time(k))


def latest_key(site: str) -> str:
    today = dt.datetime.now(dt.timezone.utc).date()
    for day in (today, today - dt.timedelta(days=1)):
        keys = list_keys(site, day)
        if keys:
            return keys[-1]
    raise SystemExit(f"no volumes found for {site} in the last two days")


def key_at(site: str, at: dt.datetime) -> str:
    """Newest key whose scan start is at or before `at`."""
    for day in (at.date(), at.date() - dt.timedelta(days=1)):
        keys = [k for k in list_keys(site, day) if key_time(k) <= at]
        if keys:
            return keys[-1]
    raise SystemExit(f"no volumes for {site} at or before {at.isoformat()}")


def keys_between(site: str, start: dt.datetime, end: dt.datetime) -> list[str]:
    out: list[str] = []
    day = start.date()
    while day <= end.date():
        out += [k for k in list_keys(site, day) if start <= key_time(k) <= end]
        day += dt.timedelta(days=1)
    return out


def download(key: str) -> Path:
    dest = RAW_DIR / key.rsplit("/", 1)[-1]
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        print(f"already have {dest.name}", file=sys.stderr)
        return dest
    print(f"downloading {key}", file=sys.stderr)
    with requests.get(f"{BUCKET}/{key}", stream=True, timeout=120) as r:
        r.raise_for_status()
        with open(dest, "wb") as f:
            for chunk in r.iter_content(1 << 20):
                f.write(chunk)
    return dest


def resolve_keys(args) -> list[str]:
    if args.start or args.end:
        if not (args.start and args.end):
            raise SystemExit("--from and --to must be given together")
        return keys_between(args.site, parse_time(args.start), parse_time(args.end))
    if args.at:
        return [key_at(args.site, parse_time(args.at))]
    return [latest_key(args.site)]


def write_volume(vol: level2.Volume) -> Path:
    """Write a decoded Volume to data/volumes/<ICAO>_<time>/ in the Godot-facing layout."""
    out = VOLUMES_DIR / f"{vol.icao}_{vol.time:%Y%m%d_%H%M%S}"
    out.mkdir(parents=True, exist_ok=True)

    sweeps_meta = []
    for i, radials in enumerate(vol.sweeps()):
        res = radials[0].azimuth_resolution
        step = 0.5 if res == 1 else 1.0
        n_bins = int(round(360.0 / step))
        fields_meta = {}

        names = sorted({m for r in radials for m in r.moments})
        for name in names:
            moments = [r.moments[name] for r in radials if name in r.moments]
            n_gates = max(m.n_gates for m in moments)
            grid = np.full((n_bins, n_gates), level2.MISSING, dtype=np.float32)
            for r in radials:
                m = r.moments.get(name)
                if m is None:
                    continue
                b = int(r.azimuth / step) % n_bins
                grid[b, : m.n_gates] = m.values
            fname = f"s{i:02d}_{name}.bin"
            tmp = out / (fname + ".tmp")
            grid.astype("<f2").tofile(tmp)
            tmp.replace(out / fname)  # atomic swap so Godot never reads a half-written file
            fields_meta[name] = {
                "file": fname,
                "n_gates": n_gates,
                "first_gate_m": moments[0].first_gate_m,
                "gate_spacing_m": moments[0].gate_spacing_m,
            }

        sweeps_meta.append(
            {
                "index": i,
                "elevation_number": radials[0].elevation_number,
                "elevation_deg": round(float(np.mean([r.elevation for r in radials])), 3),
                "azimuth_step_deg": step,
                "n_azimuth_bins": n_bins,
                "n_radials": len(radials),
                "time": radials[0].time.isoformat(),
                "nyquist_ms": radials[0].nyquist_ms,
                "unambiguous_range_km": radials[0].unambiguous_range_km,
                "fields": fields_meta,
            }
        )

    meta = {
        "format_version": 1,
        "icao": vol.icao,
        "time": vol.time.isoformat(),
        "latitude": vol.latitude,
        "longitude": vol.longitude,
        "height_m": vol.height_m,
        "vcp": vol.vcp,
        "complete": vol.complete,
        "dtype": "float16-le",
        "layout": "row-major [azimuth_bin][gate]; bin b covers [b*step, (b+1)*step) degrees clockwise from north",
        "missing": level2.MISSING,
        "range_folded": level2.RANGE_FOLDED,
        "sweeps": sweeps_meta,
    }
    tmp = out / "volume.json.tmp"
    tmp.write_text(json.dumps(meta, indent=2))
    tmp.replace(out / "volume.json")
    return out


def decode(path: Path) -> Path:
    return write_volume(level2.read_file(str(path)))


def live(site: str, interval: float) -> None:
    site = site.upper()
    print(f"locating newest {site} volume...", file=sys.stderr)
    volume = chunks.find_latest_volume(site)
    seen: set[str] = set()
    buf = bytearray()
    finished: dt.datetime | None = None  # start time of the last volume we completed

    while True:
        keys = chunks.list_chunks(site, volume, newer_than=finished)
        new = [k for k in keys if k not in seen]
        if new:
            if not buf and not new[0].endswith("-S"):
                # Joined mid-volume: skip to the next one rather than decode a headerless buffer.
                print(f"{site}/{volume}: mid-volume, waiting for next", file=sys.stderr)
                seen.update(keys)
                if keys[-1].endswith("-E"):
                    finished = chunks.chunk_time(keys[-1])
                    volume, seen = chunks.next_volume(volume), set()
                time.sleep(interval)
                continue
            for k in new:
                buf += chunks.fetch_chunk(k)
                seen.add(k)
            try:
                vol = level2.read_volume(bytes(buf))
                vol.complete = keys[-1].endswith("-E")
                out = write_volume(vol)
                print(f"{out.name}: {len(vol.sweeps())} sweeps ({len(seen)} chunks){' complete' if vol.complete else ''}", file=sys.stderr)
            except ValueError as e:  # e.g. only the metadata chunk has arrived so far
                print(f"{site}/{volume}: {e}", file=sys.stderr)
            except (OSError, EOFError) as e:
                # A torn or foreign chunk; keep following rather than die. The next volume
                # starts from a fresh buffer.
                print(f"{site}/{volume}: decode failed: {e}", file=sys.stderr)
            if keys[-1].endswith("-E"):
                finished = chunks.chunk_time(keys[-1])
                volume, seen, buf = chunks.next_volume(volume), set(), bytearray()
                continue
        time.sleep(interval)


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="python -m nexrad", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def with_time_opts(p):
        p.add_argument("site")
        p.add_argument("--at", help="ISO time; newest volume at or before it")
        p.add_argument("--from", dest="start", help="ISO time; start of range (with --to)")
        p.add_argument("--to", dest="end", help="ISO time; end of range (with --from)")

    sub.add_parser("latest").add_argument("site")
    with_time_opts(sub.add_parser("fetch"))
    with_time_opts(sub.add_parser("update"))
    sub.add_parser("decode").add_argument("path", nargs="+")
    lp = sub.add_parser("live")
    lp.add_argument("site")
    lp.add_argument("--interval", type=float, default=5.0, help="poll interval in seconds")
    sub.add_parser("basemap")
    args = ap.parse_args(argv)

    if args.cmd == "latest":
        print(latest_key(args.site))
    elif args.cmd == "fetch":
        for k in resolve_keys(args):
            print(download(k))
    elif args.cmd == "update":
        for k in resolve_keys(args):
            print(decode(download(k)))
    elif args.cmd == "decode":
        for p in args.path:
            print(decode(Path(p)))
    elif args.cmd == "live":
        live(args.site, args.interval)
    elif args.cmd == "basemap":
        print(basemap.build(BASEMAP_DIR, RAW_DIR / "basemap"))


if __name__ == "__main__":
    main()
