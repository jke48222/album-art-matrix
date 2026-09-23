"""Spin preserves artwork geometry and remains stable around bad timing data."""
import math
import numpy as np
from PIL import Image, ImageOps
import pytest
from brain.art.disc import DiscAnimator


@pytest.fixture
def art():
    pixels = np.zeros((48, 96, 3), dtype=np.uint8)
    pixels[:, :24] = (255, 0, 0)
    pixels[:, 24:72] = (20, 160, 100)
    pixels[:, 72:] = (0, 0, 255)
    pixels[12:36, 36:60] = (240, 200, 50)
    return Image.fromarray(pixels)


@pytest.mark.parametrize('side', [64, 192])
@pytest.mark.parametrize('pressed', [False, True])
def test_rectangular_cover_matches_center_square(art, side, pressed):
    crop = ImageOps.fit(art, (48, 48), method=Image.Resampling.LANCZOS)
    actual = DiscAnimator(art, side, pressed=pressed).frame_at(0, progress_s=93, fraction=0.4)
    expected = DiscAnimator(crop, side, pressed=pressed).frame_at(0, progress_s=93, fraction=0.4)
    # Lanczos can sample one edge pixel beyond the square when fitting directly.
    difference = np.abs(np.asarray(actual).astype(float) - np.asarray(expected).astype(float))
    assert difference.mean() < 1
    assert actual.size == (side, side)


def test_song_position_freezes_rotation_during_pause(art):
    disc = DiscAnimator(art, 64)
    assert disc.frame_at(10, progress_s=93).tobytes() == disc.frame_at(500, progress_s=93).tobytes()
    assert disc.frame_at(10, progress_s=94).tobytes() != disc.frame_at(10, progress_s=93).tobytes()


@pytest.mark.parametrize('value', [math.nan, math.inf, -math.inf])
def test_nonfinite_time_and_needle_do_not_poison_frame(art, value):
    disc = DiscAnimator(art, 64, rpm=value)
    assert disc.frame_at(value, fraction=value).tobytes() == disc.frame_at(0).tobytes()


@pytest.mark.parametrize('size', [0, -1, 513, 64.5])
def test_invalid_size_is_rejected_before_allocation(art, size):
    with pytest.raises(ValueError): DiscAnimator(art, size)
