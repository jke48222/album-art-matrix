"""Letter Boxed: a puzzle with a known two-word solution and a legal
layout, the side rule, chaining, undo, the box at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_letterboxed.py -q
"""
import os
import random
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.letterboxed import LetterBoxed, make_puzzle, sides_for   # noqa: E402
from brain.games.words import common                                       # noqa: E402
from brain.games.host import GameHost                                      # noqa: E402
from brain.tests.test_games import FakeCtrl                                # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_puzzles_have_a_legal_solution():
    for seed in range(3):
        sides, (a, b) = make_puzzle(random.Random(seed), common(3, 12))
        assert len(sides) == 4 and all(len(s) == 3 for s in sides)
        letters = set("".join(sides))
        assert len(letters) == 12 and set(a) | set(b) == letters and a[-1] == b[0]
        side_of = {ch: i for i, s in enumerate(sides) for ch in s}
        for w in (a, b):
            assert all(side_of[x] != side_of[y] for x, y in zip(w, w[1:]))
    assert sides_for(("abc", "cdef"), random.Random(0)) is None            # not twelve letters


def test_play_chain_and_undo(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("letterboxed", {"seed": 1})
    g = host.game
    a, b = g.par
    assert host.move(None, {"word": "xq"})["error"] == "three letters or more"
    r = host.hear(a)
    assert r["word"] == a and r["left"] == 12 - len(set(a))
    wrong_start = next((w for w in common(3, 8) if set(w) <= g.letters and w[0] != a[-1]
                        and g.check(w) and "start with" in g.check(w)), None)
    if wrong_start:
        assert "must start with" in host.move(None, {"word": wrong_start})["error"]
    assert host.hear("undo")["undone"] and g.words == []
    host.move(None, {"word": a})
    r = host.move(None, {"word": b})
    assert g.over and g.won and g.message.startswith("Solved in 2") and "Par" in g.message
    assert host.status()["game"]["solution"] == [a, b]


def test_the_box_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("letterboxed", {"seed": 2})
    g = host.game
    host.move(None, {"word": g.par[0]})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        yellow = ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum()
        assert yellow > 10                                                # the word's lines
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"letterboxed-{size}.png"))
