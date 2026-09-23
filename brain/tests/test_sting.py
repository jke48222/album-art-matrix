"""The sting on the wall's dots: the boot cut and the waiting loop."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.art import sting as S                 # noqa: E402
from brain.control import ControlState            # noqa: E402


def lit(f, x0=0, x1=None, thresh=120):
    x1 = f.shape[1] if x1 is None else x1
    return int((f[:, x0:x1].max(axis=2) > thresh).sum())


def test_the_disc_arrives_then_the_wordmark_at_64():
    s = S.Sting(64)
    assert s.pitch == 2 and s.word_scale == 1
    first = s.frame(0.0)
    assert first.shape == (64, 64, 3) and first.dtype == np.uint8
    assert lit(first) == 0                                # nothing white yet
    built = s.frame(1.3)                                  # spun to rest, centred, before the wipe
    assert 40 <= lit(built, 16, 48) <= 110                # 68 tiles of one LED, a few straddling
    assert lit(built, 44, 64) <= 5                        # no wordmark yet
    end = s.frame(S.BOOT_S - 0.05)
    assert lit(end, 0, 24) >= 40                          # the disc, slid to the left
    assert lit(end, 24, 64) >= 30                         # TESSERA, on the right


def test_the_boot_cut_is_a_clip_of_bytes_at_the_walls_size():
    frames = S.Sting(64).boot_frames()
    assert len(frames) == int(S.BOOT_S * S.FPS)
    assert all(len(b) == 64 * 64 * 3 for b in frames)


def test_the_icon_loop_builds_holds_fades_and_goes_round():
    s = S.Sting(64)
    assert lit(s.icon_frame(0.02)) == 0
    assert lit(s.icon_frame(1.6)) >= 40
    assert lit(s.icon_frame(S.LOOP_S - 0.02)) <= 4        # faded out
    assert lit(s.icon_frame(S.LOOP_S + 1.6)) >= 40        # round again
    assert lit(s.icon_frame(1.6), 0, 20) == 0 and lit(s.icon_frame(1.6), 44, 64) == 0   # centred, alone


def test_a_bigger_wall_gets_bigger_dots_and_the_mark_still_fits():
    s = S.Sting(192)
    assert s.pitch == 6 and s.word_scale == 3
    assert s.word_x + S.text_width("TESSERA", 3) <= 192
    end = s.frame(S.BOOT_S - 0.05)
    assert lit(end, 0, 80) > 400 and lit(end, 80, 192) > 200


def test_the_wall_plays_the_sting_as_a_clip_once():
    ctrl = ControlState(frame_len=64 * 64 * 3)
    ctrl.apply({"mode": "lyrics"})
    ctrl.play_sting()
    assert ctrl.get()["mode"] == "clip"
    assert ctrl.clip["once"] and ctrl.clip["ret"] == "lyrics"
    assert len(ctrl.clip["frames"]) == int(S.BOOT_S * S.FPS)
