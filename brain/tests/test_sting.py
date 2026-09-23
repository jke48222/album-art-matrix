"""The sting on the wall: the final render, cut for a square, in two cuts."""
import os
import shutil
import sys

import numpy as np
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.art import sting as S                 # noqa: E402
from brain.control import ControlState            # noqa: E402

pytestmark = pytest.mark.skipif(not shutil.which("ffmpeg"), reason="decoding the film needs ffmpeg")


@pytest.fixture(scope="module")
def sting64(tmp_path_factory):
    S.CACHE_DIR = str(tmp_path_factory.mktemp("cache"))   # never the real cache
    s = S.Sting(64)
    assert s.ensure()
    return s


def lit_rows(f, thresh=120):
    return np.where((f.max(axis=2) > thresh).any(axis=1))[0]


def lit_cols(f, thresh=120):
    return np.where((f.max(axis=2) > thresh).any(axis=0))[0]


def test_the_whole_film_at_the_walls_size(sting64):
    assert sting64.frames.shape[1:] == (64, 64, 3) and sting64.frames.dtype == np.uint8
    assert 100 <= len(sting64.frames) <= 130                  # five seconds at 24
    frames = sting64.boot_frames()
    assert len(frames) == len(sting64.frames) and all(len(b) == 64 * 64 * 3 for b in frames)


def test_the_disc_alone_fills_the_square_and_the_lockup_is_a_strip(sting64):
    disc = sting64.frames[int(1.6 * S.FPS)]                   # settled, before the name
    rows, cols = lit_rows(disc), lit_cols(disc)
    assert rows.size >= 30 and cols.size >= 30                 # big on the panel
    assert abs(rows.size - cols.size) <= 8                     # and square
    end = sting64.frames[-1]                                   # the lockup
    rows, cols = lit_rows(end), lit_cols(end)
    assert cols.max() - cols.min() >= 40                       # wide: the whole lockup, with its margin
    assert rows.max() - rows.min() <= 26                       # letterboxed
    assert cols.min() < 20 and cols.max() > 44                 # disc left, name right


def test_the_loop_is_the_disc_before_the_name(sting64):
    assert 1.5 * S.FPS <= sting64.loop_end <= 3.2 * S.FPS
    for i in range(sting64.loop_end):
        f = sting64.frames[i]
        c = lit_cols(f)
        assert c.size == 0 or c.max() - c.min() <= 58           # never the wide lockup (the disc overshoots a little as it locks)
    assert sting64.icon_frame(0.0).shape == (64, 64, 3)
    assert lit_cols(sting64.icon_frame(1.6)).size >= 30
    later = sting64.icon_frame(sting64.loop_end / S.FPS + 1.6)   # round again
    assert np.array_equal(later, sting64.icon_frame(1.6))


def test_the_frames_are_kept_and_found_again(sting64):
    again = S.Sting(64)
    assert again.ensure() and again.loop_end == sting64.loop_end
    assert np.array_equal(again.frames[40], sting64.frames[40])


def test_the_wall_plays_the_sting_as_a_clip_once(sting64, monkeypatch):
    monkeypatch.setattr(S.Sting, "get", classmethod(lambda cls, size, video=None: sting64))
    ctrl = ControlState(frame_len=64 * 64 * 3)
    ctrl.apply({"mode": "lyrics"})
    ctrl.play_sting()
    assert ctrl.get()["mode"] == "clip"
    assert ctrl.clip["once"] and ctrl.clip["ret"] == "lyrics"
    assert len(ctrl.clip["frames"]) == len(sting64.frames)


def test_a_missing_film_is_a_quiet_no(tmp_path):
    S.CACHE_DIR = str(tmp_path)
    s = S.Sting(64, video=str(tmp_path / "nowhere.mp4"))
    assert not s.ensure() and s.boot_frames() == [] and s.icon_frame(1.0) is None
