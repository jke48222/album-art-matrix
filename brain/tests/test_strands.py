"""Strands: bundled sets thread into a full grid with the spangram across
it, words found by voice light their paths, extras earn hints, the grid
at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_strands.py -q
"""
import os
import random
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.strands import BUNDLED, build, thread, spangram_ok, ROWS, COLS, NEIGH   # noqa: E402
from brain.games.host import GameHost                                                     # noqa: E402
from brain.tests.test_games import FakeCtrl                                               # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_bundled_sets_add_up_and_thread():
    for theme, span, words in BUNDLED:
        assert len(span) + sum(len(w) for w in words) == ROWS * COLS, theme
    theme, span, words = BUNDLED[0]
    built = build(theme, span, words, random.Random(1), 12.0)
    assert built is not None
    grid, paths = built
    assert all(all(ch for ch in row) for row in grid)
    assert spangram_ok(paths[0])
    cells = [cell for p in paths for cell in p]
    assert len(cells) == ROWS * COLS and len(set(cells)) == ROWS * COLS
    for w, p in zip([span] + words, paths):
        assert "".join(grid[r][c] for r, c in p) == w
        assert all(abs(a[0] - b[0]) <= 1 and abs(a[1] - b[1]) <= 1 for a, b in zip(p, p[1:]))
    assert thread(["abc"], random.Random(0), 0.2) is None                 # not 48 letters


def test_play(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    st = host.start("strands", {"set": 0, "seed": 1}, ["Jalen"])
    g = host.game
    assert st["game"]["theme"] == g.theme and len(st["game"]["rows"]) == ROWS
    r = host.hear(g.words[0], "Jalen")
    assert r["theme_word"] and r["path"] == g.path_of(g.words[0])
    assert host.hear(g.words[0], "Jalen")["error"] == "already found"
    assert host.hear("what time is it", "Jalen") is None
    assert host.move("Jalen", {"hint": True})["error"].startswith("find three")
    r = host.hear(g.spangram, "Jalen")
    assert r["spangram"] and g.message == "The spangram!"
    for w in g.words[1:]:
        host.move("Jalen", {"word": w})
    assert g.over and g.won and host.status()["game"]["answers"][0] == g.spangram


def test_the_grid_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("strands", {"set": 1, "seed": 2})
    g = host.game
    host.move(None, {"word": g.words[0]})
    host.move(None, {"word": g.spangram})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        blue = ((f[..., 2] > 150) & (f[..., 0] < 120)).sum()
        yellow = ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum()
        assert blue > 20 and yellow > 20
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"strands-{size}.png"))
