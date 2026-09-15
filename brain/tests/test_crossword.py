"""The mini crossword: slots numbered the crossword way, a fill from the
common words for every pattern, entering by voice and by letter, check,
the grid at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_crossword.py -q
"""
import os
import random
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.crossword import PATTERNS, BUNDLED, slots, fill_grid, N   # noqa: E402
from brain.games.words import common, common_set                          # noqa: E402
from brain.games.host import GameHost                                     # noqa: E402
from brain.tests.test_games import FakeCtrl                               # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_slots_are_numbered_the_crossword_way():
    sl = slots(set(BUNDLED[0][0]))
    ids = [s["id"] for s in sl]
    assert ids[:3] == ["1A", "1D", "2D"] and "5A" in ids and "5D" in ids
    assert len(sl) == 10


def test_every_pattern_fills():
    by_len = {}
    for w in common(3, 5, 8000):
        by_len.setdefault(len(w), []).append(w)
    for pattern in PATTERNS:
        grid = fill_grid(set(pattern), random.Random(1), by_len)
        assert grid is not None, pattern
        for s in slots(set(pattern)):
            w = "".join(grid[c] for c in s["cells"])
            assert w in common_set(), (pattern, w)


def test_bundled_is_sound_and_plays(tmp_path):
    blacks, rows, clues = BUNDLED[0]
    sl = slots(set(blacks))
    assert set(clues) == {s["id"] for s in sl}
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    st = host.start("crossword", {"set": 0})
    g = host.game
    assert len(st["game"]["slots"]) == 10 and st["game"]["slots"][0]["clue"] == "Bedside light"
    r = host.hear("one across is lamp")
    assert r["filled"] == 4
    assert host.hear("one across is lamps")["error"] == "1A is 4 letters"
    host.move(None, {"cell": [1, 0], "letter": "x"})
    r = host.hear("check")
    assert r["wrong"] == [[1, 0]]
    for s in sl:
        word = "".join(g.solution[c] for c in s["cells"])
        host.move(None, {"slot": s["id"], "word": word})
    assert g.over and g.won and host.status()["game"]["solution"][0] == ["#", "l", "a", "m", "p"]


def test_the_grid_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("crossword", {"set": 0})
    host.hear("one across is lamp")
    host.move(None, {"cell": [1, 0], "letter": "x"})
    host.hear("check")
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        assert ((f[..., 0] > 150) & (f[..., 1] < 90)).sum() > 3               # the red x
        assert ((f[..., 0] > 200) & (f[..., 1] > 200)).sum() > 20             # lamp in ink
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"crossword-{size}.png"))
