"""Real-time NEXRAD Level II via Unidata's chunks bucket.

Layout: unidata-nexrad-level2-chunks/<SITE>/<volume 1..999>/<YYYYMMDD-HHMMSS>-<chunk>-<S|I|E>
Volume numbers wrap around at 999, and a reused number's directory can still hold the
previous cycle's chunks (days old) next to the new ones, so every lookup keys on the
newest timestamp prefix in the directory. Each chunk is one or more whole LDM compressed
records; the S chunk also carries the 24-byte Archive2 header. Concatenating
S + I... + E byte-for-byte yields a normal archive file, so the same decoder works
on a partial volume as chunks arrive (typically within ~5-10 s of the sweep).
"""

from __future__ import annotations

import datetime as dt
import xml.etree.ElementTree as ET

import requests

BUCKET = "https://unidata-nexrad-level2-chunks.s3.amazonaws.com"
S3_NS = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
MAX_VOLUME = 999


def _list(prefix: str, max_keys: int = 1000) -> list[str]:
    resp = requests.get(
        BUCKET, params={"list-type": "2", "prefix": prefix, "max-keys": str(max_keys)}, timeout=60
    )
    resp.raise_for_status()
    root = ET.fromstring(resp.text)
    return [el.text for el in root.findall("s3:Contents/s3:Key", S3_NS) if el.text]


def _stamp(key: str) -> str:
    return key.rsplit("/", 1)[-1][:15]


def list_chunks(site: str, volume: int, newer_than: dt.datetime | None = None) -> list[str]:
    """Chunk keys of the newest volume stored under this number, in chunk order.

    Leftover chunks from the previous trip around the ring are dropped. With `newer_than`,
    returns [] unless that newest volume started after it (i.e. the directory only holds
    leftovers so far).
    """
    keys = _list(f"{site.upper()}/{volume}/")
    if not keys:
        return []
    newest = max(_stamp(k) for k in keys)
    if newer_than is not None and _parse_stamp(newest) <= newer_than:
        return []
    keys = [k for k in keys if _stamp(k) == newest]
    return sorted(keys, key=lambda k: int(k.rsplit("/", 1)[-1].split("-")[2]))


def _parse_stamp(stamp: str) -> dt.datetime:
    return dt.datetime.strptime(stamp, "%Y%m%d-%H%M%S").replace(tzinfo=dt.timezone.utc)


def chunk_time(key: str) -> dt.datetime:
    return _parse_stamp(_stamp(key))


def volume_time(site: str, volume: int) -> dt.datetime | None:
    """Start time of the newest volume stored under this number (ignores leftovers)."""
    keys = _list(f"{site.upper()}/{volume}/")
    return _parse_stamp(max(_stamp(k) for k in keys)) if keys else None


def next_volume(volume: int) -> int:
    return 1 if volume >= MAX_VOLUME else volume + 1


def find_latest_volume(site: str) -> int:
    """Locate the newest volume number in the circular 1..999 buffer.

    Times increase with volume number except at one wrap point. Sample coarsely,
    then binary-search the segment after the newest sample for the last number
    whose time is still >= the sample's time. ~20 requests total.
    """
    step = 100
    samples = list(range(1, MAX_VOLUME + 1, step))
    times = {n: volume_time(site, n) for n in samples}
    known = {n: t for n, t in times.items() if t is not None}
    if not known:
        raise RuntimeError(f"no chunks found for {site}")
    start = max(known, key=known.get)
    base = known[start]

    lo, hi = start, min(start + step - 1, MAX_VOLUME)
    while lo < hi:
        mid = (lo + hi + 1) // 2
        t = volume_time(site, mid)
        if t is not None and t >= base:
            lo = mid
        else:
            hi = mid - 1
    return lo


def fetch_chunk(key: str) -> bytes:
    resp = requests.get(f"{BUCKET}/{key}", timeout=60)
    resp.raise_for_status()
    return resp.content
