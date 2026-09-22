import datetime as dt
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from nexrad import synth  # noqa: E402

T0 = dt.datetime(2024, 5, 1, 22, 0, 0, tzinfo=dt.timezone.utc)
SITE = synth.Site("KTST", 35.3331, -97.2778, 370.0)
# A quick scan for tests that do not need the whole VCP: one split cut, one batch tilt.
SMALL_SCAN = (
    synth.Tilt(0.5, 0.5, synth.SURVEILLANCE),
    synth.Tilt(0.5, 0.5, synth.DOPPLER),
    synth.Tilt(1.5, 1.0, synth.ALL),
)


@pytest.fixture(scope="session")
def scene():
    return synth.Scene(origin=(SITE.latitude, SITE.longitude), t0=T0)


@pytest.fixture(scope="session")
def small_volume(scene):
    return scene.volume(SITE, T0, SMALL_SCAN)


@pytest.fixture(scope="session")
def fixture_root(tmp_path_factory):
    root = tmp_path_factory.mktemp("fixtures") / "volumes"
    synth.build_fixtures(root)
    return root
