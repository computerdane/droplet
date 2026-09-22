import datetime as dt
import json

import pytest

from nexrad import __main__ as cli
from nexrad import chunks, synth

from fakes import FakeResponse, s3_listing

UTC = dt.timezone.utc


def test_list_parses_s3_xml(monkeypatch):
    seen = {}

    def get(url, params, timeout):
        seen.update(url=url, **params)
        return FakeResponse(s3_listing(["KTST/5/20240501-220000-001-S", "KTST/5/20240501-220000-002-I"]))

    monkeypatch.setattr(chunks.requests, "get", get)
    assert chunks._list("KTST/5/") == ["KTST/5/20240501-220000-001-S", "KTST/5/20240501-220000-002-I"]
    assert seen["prefix"] == "KTST/5/" and seen["list-type"] == "2"


def test_list_chunks_drops_leftovers_and_sorts_numerically(monkeypatch):
    new = [f"KTST/5/20240501-220000-{n:03d}-{'S' if n == 1 else 'I'}" for n in (1, 2, 10, 9)]
    old = ["KTST/5/20240425-101500-001-S", "KTST/5/20240425-101500-044-E"]
    monkeypatch.setattr(chunks, "_list", lambda prefix: old + new)
    got = chunks.list_chunks("ktst", 5)
    assert [k.rsplit("-", 2)[1] for k in got] == ["001", "002", "009", "010"]
    assert chunks.list_chunks("KTST", 5, newer_than=dt.datetime(2024, 5, 1, 21, 55, tzinfo=UTC)) == got
    assert chunks.list_chunks("KTST", 5, newer_than=dt.datetime(2024, 5, 1, 22, 0, tzinfo=UTC)) == []
    monkeypatch.setattr(chunks, "_list", lambda prefix: [])
    assert chunks.list_chunks("KTST", 5) == []


def test_times_and_ring_wrap():
    assert chunks.chunk_time("KTST/5/20240501-220013-003-I") == dt.datetime(2024, 5, 1, 22, 0, 13, tzinfo=UTC)
    assert chunks.next_volume(998) == 999
    assert chunks.next_volume(999) == 1


@pytest.mark.parametrize("newest", [1, 57, 437, 999])
@pytest.mark.parametrize("full", [True, False])
def test_find_latest_volume(monkeypatch, newest, full):
    """Numbers after `newest` hold the previous trip around the ring (older), or nothing yet."""
    base = dt.datetime(2024, 5, 1, 22, 0, tzinfo=UTC)
    calls = []

    def listing(prefix):
        calls.append(prefix)
        n = int(prefix.split("/")[1])
        if not full and n > newest:
            return []
        age = (newest - n) % chunks.MAX_VOLUME  # volumes back in time from the newest
        t = base - dt.timedelta(minutes=5 * age)
        return [f"KTST/{n}/{t:%Y%m%d-%H%M%S}-001-S"]

    monkeypatch.setattr(chunks, "_list", listing)
    assert chunks.find_latest_volume("KTST") == newest
    assert len(calls) <= 20


def test_live_follows_a_growing_volume(monkeypatch, tmp_path, small_volume, capsys):
    """live(): starts on an in-progress volume from its S chunk, rewrites the partial volume
    as chunks arrive, marks it complete on the E chunk, then moves on to the next number."""
    parts = synth.ldm_records(synth.encode_archive(small_volume))
    payloads = [parts[0] + parts[1]] + parts[2:]  # S = header + metadata record
    stamp = f"{small_volume.time:%Y%m%d-%H%M%S}"
    keys = [
        f"KTST/7/{stamp}-{i + 1:03d}-{'S' if i == 0 else 'E' if i == len(payloads) - 1 else 'I'}"
        for i in range(len(payloads))
    ]
    data = dict(zip(keys, payloads))
    state = {"visible": 1, "polls": 0}

    def listing(prefix):
        if prefix == "KTST/7/":
            return ["KTST/7/20240420-000000-001-S"] + keys[: state["visible"]]  # plus leftovers
        return []

    class Stop(Exception):
        pass

    def sleep(_):
        state["polls"] += 1
        state["visible"] = min(state["visible"] + 3, len(keys))
        if state["polls"] > 12:
            raise Stop

    monkeypatch.setattr(chunks, "_list", listing)
    monkeypatch.setattr(chunks, "find_latest_volume", lambda site: 7)
    monkeypatch.setattr(chunks, "fetch_chunk", data.__getitem__)
    monkeypatch.setattr(cli, "VOLUMES_DIR", tmp_path)
    monkeypatch.setattr(cli.time, "sleep", sleep)
    with pytest.raises(Stop):
        cli.live("ktst", 0.0)

    log = capsys.readouterr().err.splitlines()
    name = f"KTST_{small_volume.time:%Y%m%d_%H%M%S}"
    writes = [line for line in log if line.startswith(name)]
    assert len(writes) >= 3
    assert not writes[0].endswith("complete") and writes[-1].endswith("complete")
    meta = json.loads((tmp_path / name / "volume.json").read_text())
    assert meta["complete"] is True
    assert len(meta["sweeps"]) == 3
    assert not list(tmp_path.rglob("*.tmp"))


def test_live_skips_a_volume_joined_mid_way(monkeypatch, tmp_path, capsys):
    keys = ["KTST/7/20240501-220000-004-I", "KTST/7/20240501-220000-005-E"]
    polls = []

    class Stop(Exception):
        pass

    def listing(prefix):
        return keys if prefix == "KTST/7/" else []

    def sleep(_):
        polls.append(1)
        if len(polls) > 2:
            raise Stop

    monkeypatch.setattr(chunks, "_list", listing)
    monkeypatch.setattr(chunks, "find_latest_volume", lambda site: 7)
    monkeypatch.setattr(chunks, "fetch_chunk", lambda k: pytest.fail("fetched a mid-volume chunk"))
    monkeypatch.setattr(cli, "VOLUMES_DIR", tmp_path)
    monkeypatch.setattr(cli.time, "sleep", sleep)
    with pytest.raises(Stop):
        cli.live("KTST", 0.0)
    assert "mid-volume" in capsys.readouterr().err
    assert not list(tmp_path.iterdir())
