"""Both physical geometries obey the timing and preserve their destination."""
import numpy as np
import pytest
from brain.art.horizon import Horizon, COLLAPSE, OPEN, DASH, CLOSE

@pytest.mark.parametrize('size', [64, 192])
def test_horizon_lifecycle(size):
    now = [0.]
    source = np.zeros((size, size, 3), dtype=np.uint8)
    source[:, :size//2] = (220, 90, 30)
    source[:, size//2:] = (20, 60, 110)
    face = Horizon(size, source.tobytes(), lambda: now[0])
    assert np.array_equal(face.frame_at(0), source)
    now[0] = COLLAPSE
    frame = face.frame_at(COLLAPSE)
    ys = np.flatnonzero(frame.any(axis=(1,2)))
    assert len(ys) == size//64
    face.think()
    assert not np.array_equal(face.frame_at(0), face.frame_at(.6))
    face.open()
    assert face.waiting
    destination = np.full_like(source, 80)
    face.target(destination)
    now[0] += OPEN
    assert face.done and np.array_equal(face.frame_at(OPEN), destination)
    face.fail()
    assert face.frame_at(0).any()
    now[0] += DASH+CLOSE
    assert face.done and not face.frame_at(DASH+CLOSE).any()


def test_ink_is_saturated_and_level_releases():
    now = [1.]
    frame = np.full((64,64,3), 250, dtype=np.uint8)
    frame[10,10] = (220,80,20)
    face = Horizon(64, frame.tobytes(), lambda: now[0])
    assert tuple(face.ink) == (220,80,20)
    now[0] += 1
    face.level(-20)
    loud = face.frame_at(1).sum()
    now[0] += .8
    assert face.frame_at(1.8).sum() < loud
