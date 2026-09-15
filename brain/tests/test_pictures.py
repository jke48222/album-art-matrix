"""The sliding puzzle and the cover reveal on a sleeve: a solvable
scramble, slides by touch and voice, the blur that sharpens, a guess by
album or artist, both at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_pictures.py -q
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                       # noqa: E402
from brain.games import pictures                            # noqa: E402,F401
from brain.tests.test_games import FakeCtrl                 # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def sleeve(tmp_path):
    img = Image.new("RGB", (600, 600), (240, 220, 190))
    d = ImageDraw.Draw(img)
    d.rectangle((40, 40, 560, 560), fill=(30, 80, 190))
    d.ellipse((150, 150, 450, 450), fill=(250, 200, 40))
    d.rectangle((0, 0, 300, 300), outline=(0, 0, 0), width=8)
    p = tmp_path / "sleeve.png"
    img.save(p)
    return str(p)


class Ctrl(FakeCtrl):
    def __init__(self, w=64):
        super().__init__()
        self.wall = type("W", (), {"width": w})()
        self.now_showing = {}
    def journal_read(self, n):
        return []


def test_sliding(tmp_path):
    path = sleeve(tmp_path)
    for size, scale in ((64, 4), (192, 2)):
        host = GameHost(Ctrl(size), path=str(tmp_path / "g.json"))
        st = host.start("sliding", {"image": path, "seed": 1, "grid": 3})
        g = host.game
        assert sorted(g.tiles) == list(range(9)) and g.tiles != list(range(9))
        f = host.frame_at(size)
        assert f.shape == (size, size, 3) and f.max() > 100
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"sliding-{size}.png"))
        assert host.move(None, {"tile": g.gap})["error"]                   # the gap itself
        r = None
        for d in ("up", "down", "left", "right"):
            r = host.hear(d)
            if r and "error" not in r:
                break
        assert r and r["moves"] == 1
        # solve it: undo the scramble by search is overkill; walk the tiles home with a solver
        solve(host)
        assert g.over and g.won and g.message.startswith("Back in")
        g.changed_at -= 2.0                                   # past the wash of light
        sharp = host.frame_at(size)
        cell = size // 3
        want = np.asarray(g.sleeve.resize((size, size)) if g.sleeve.size[0] != size else g.sleeve)
        assert np.array_equal(sharp[:cell * 3, :cell * 3], want[:cell * 3, :cell * 3])


def solve(host):
    """Breadth-first over the 3x3 states from here; small enough."""
    from collections import deque
    g = host.game
    start = tuple(g.tiles)
    goal = tuple(range(9))
    prev = {start: None}
    q = deque([start])
    def moves_of(state):
        gap = state.index(8)
        r, c = divmod(gap, 3)
        out = []
        if r > 0: out.append(gap - 3)
        if r < 2: out.append(gap + 3)
        if c > 0: out.append(gap - 1)
        if c < 2: out.append(gap + 1)
        return gap, out
    while q:
        s = q.popleft()
        if s == goal:
            break
        gap, ms = moves_of(s)
        for m in ms:
            n = list(s); n[gap], n[m] = n[m], n[gap]; n = tuple(n)
            if n not in prev:
                prev[n] = (s, m); q.append(n)
    path = []
    s = goal
    while prev[s] is not None:
        s, m = prev[s]
        path.append(m)
    for m in reversed(path):
        host.move(None, {"tile": m})


def test_reveal(tmp_path):
    path = sleeve(tmp_path)
    for size, scale in ((64, 4), (192, 2)):
        host = GameHost(Ctrl(size), path=str(tmp_path / "g.json"))
        host.start("reveal", {"image": path, "title": "Nights", "artist": "Frank Ocean", "album": "Blonde",
                              "seconds": 30}, ["Jalen", "Sam"])
        g = host.game
        clock = [100.0]
        g._clock = lambda: clock[0]
        g.t0 = 100.0
        blurry = host.frame_at(size)
        clock[0] = 115.0
        half = host.frame_at(size)
        clock[0] = 129.0
        nearly = host.frame_at(size)
        sharp = np.asarray(g.sleeve.resize((size, size)) if g.sleeve.size[0] != size else g.sleeve)
        def diff(a):
            return float(np.abs(a.astype(int) - sharp.astype(int)).mean())
        assert diff(blurry) > diff(half) > diff(nearly)
        if OUT:
            strip = np.concatenate([blurry, half, nearly], axis=1)
            Image.fromarray(strip).resize((strip.shape[1] * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"reveal-{size}.png"))
        assert host.hear("channel orange", "Sam")["hit"] is False
        r = host.hear("frank ocean", "Sam")
        assert r["hit"] and g.over and g.winner == "Sam" and r["seconds"] == 29.0
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    host.start("reveal", {"image": path, "album": "Blonde", "seconds": 1})
    g = host.game
    g._clock = lambda: g.t0 + 2.0
    host.frame_at(64)
    assert g.over and not g.won and host.status()["game"]["answer"]["album"] == "Blonde"


def test_needs_a_journal(tmp_path):
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    assert "journal" in host.start("sliding", {})["error"]
