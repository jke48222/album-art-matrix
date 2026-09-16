"""A blocked artwork fetch cannot block the thread drawing the current face."""
import threading
import time
from PIL import Image
import pytest

from brain.art.loading import Sleeves, Preparing


def test_slow_fetch_hands_off_and_wakes_when_ready():
    release, started, ready = threading.Event(), threading.Event(), threading.Event()
    def fetch(url):
        started.set()
        assert release.wait(1)
        return Image.new('RGB', (80, 80), '#bea782')
    loader = Sleeves(ready.set, fetch)
    start = time.monotonic()
    with pytest.raises(Preparing):
        loader.get('fixture', 64, 1, 60)
    assert time.monotonic() - start < .1
    assert started.wait(1)
    with pytest.raises(Preparing):
        loader.get('fixture', 64, 1, 60)
    release.set()
    assert ready.wait(1)
    assert loader.get('fixture', 64, 1, 60).size == (64, 64)
    loader.pool.shutdown()
