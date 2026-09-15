"""Heardle: the steps unlock on misses and skips, a hit by title, the
reveal, the bars at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_heardle.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                  # noqa: E402
from brain.games import heardle                        # noqa: E402,F401
from brain.games.heardle import STEPS                  # noqa: E402
from brain.tests.test_pictures import Ctrl             # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")

SONG = {"title": "Nights", "artist": "Frank Ocean", "album": "Blonde", "preview": "https://example/nights.m4a"}


def test_play(tmp_path):
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    st = host.start("heardle", dict(SONG), ["Jalen", "Sam"])
    g = host.game
    assert st["game"]["seconds"] == 1 and st["game"]["preview"] == SONG["preview"] and st["game"]["answer"] is None
    assert host.hear("skip", "Jalen")["seconds"] == 2 and g.players[g.turn] == "Sam"
    assert host.hear("Pyramids", "Sam")["hit"] is False and g.seconds == 4
    r = host.move("Jalen", {"played": True})
    assert r["seconds"] == 4 and host.status()["game"]["playing"]
    r = host.hear("nights", "Jalen")
    assert r["hit"] and r["tries"] == 3 and g.over and g.won and g.winner == "Jalen"
    assert host.status()["game"]["answer"]["title"] == "Nights"


def test_six_misses(tmp_path):
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    host.start("heardle", dict(SONG))
    g = host.game
    for i in range(6):
        host.move(None, {"guess": f"wrong {i}"})
    assert g.over and not g.won and g.message == "Frank Ocean — Nights"


def test_the_bars_at_both_sizes(tmp_path):
    for size, scale in ((64, 4), (192, 2)):
        host = GameHost(Ctrl(size), path=str(tmp_path / "g.json"))
        host.start("heardle", dict(SONG))
        host.move(None, {"skip": True})
        host.move(None, {"played": True})
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        assert ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum() > 10   # the unlocked bar
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"heardle-{size}.png"))


def test_needs_a_journal(tmp_path):
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    assert "journal" in host.start("heardle", {})["error"]
