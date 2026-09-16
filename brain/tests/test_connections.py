"""Connections: bundled sets, picks and submissions, one away, four
mistakes, spoken words, the board at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_connections.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.connections import BUNDLED    # noqa: E402
from brain.games.host import GameHost                       # noqa: E402
from brain.tests.test_games import FakeCtrl                 # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_bundled_sets_are_sound():
    for groups in BUNDLED:
        assert len(groups) == 4
        words = [w for _, ws in groups for w in ws]
        assert len(words) == 16 and len(set(words)) == 16


def test_play(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    st = host.start("connections", {"set": 0}, ["Jalen"])
    g = host.game
    assert len(st["game"]["words"]) == 16 and st["game"]["mistakes_left"] == 4
    g0, g1 = g.groups[0][1], g.groups[1][1]
    r = host.move("Jalen", {"words": g0[:3] + [g1[0]]})
    assert r["one_away"] and g.mistakes == 1 and g.message == "One away."
    r = host.move("Jalen", {"words": g0})
    assert r["theme"] == g.groups[0][0] and r["colour"] == "yellow" and len(host.status()["game"]["words"]) == 12
    assert host.move("Jalen", {"words": g0})["error"] == "one of those is already placed"
    for w in g1[:3]:
        host.move("Jalen", {"pick": w})
    r = host.hear(g1[3], "Jalen")                                       # the fourth by voice submits
    assert r["colour"] == "green"
    r = host.hear(" ".join(g.groups[2][1]), "Jalen")
    assert r["colour"] == "blue"
    r = host.move("Jalen", {"words": g.groups[3][1]})
    assert g.over and g.won and g.message == "Great." and host.status()["game"]["groups"][3]["colour"] == "purple"


def test_four_mistakes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("connections", {"set": 1})
    g = host.game
    a, b = g.groups[0][1], g.groups[1][1]
    for k in range(4):
        host.move(None, {"words": a[:2] + b[k:k + 2] if k < 3 else a[1:3] + b[:2]})
    assert g.over and not g.won and g.message.startswith("Four mistakes")


def test_the_board_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("connections", {"set": 2})
    g = host.game
    host.move(None, {"words": g.groups[0][1]})
    host.move(None, {"pick": g.groups[1][1][0]})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        yellow = ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum()
        assert yellow > 100
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"connections-{size}.png"))
