"""AI pictionary with a stand-in drawer: the picture goes up, guesses
match the word, the clock runs out, the face at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_pictionary.py -q
"""
import os
import sys
import time

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                  # noqa: E402
from brain.games import pictionary                     # noqa: E402,F401
from brain.tests.test_pictures import Ctrl             # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


class FakeImaginer:
    ready = True

    def __init__(self):
        self.prompts = []

    def draw(self, prompt, expanded=None, on_partial=None):
        self.prompts.append((prompt, expanded))
        img = Image.new("RGB", (512, 512), (250, 245, 230))
        d = ImageDraw.Draw(img)
        d.ellipse((100, 150, 420, 420), fill=(120, 120, 130))
        d.rectangle((380, 260, 470, 420), fill=(120, 120, 130))
        return img


def wait_drawn(g):
    for _ in range(100):
        if not g.drawing:
            return
        time.sleep(0.02)


def test_play(tmp_path):
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    im = FakeImaginer()
    host.start("pictionary", {"word": "elephant", "imaginer": im}, ["Jalen", "Sam"])
    g = host.game
    wait_drawn(g)
    assert "elephant" in im.prompts[0][1] and "no words" in im.prompts[0][1]
    assert host.status()["game"]["drawing"] is False and g.t0 is not None
    assert host.hear("a giraffe", "Sam")["hit"] is False
    r = host.hear("elephants", "Jalen")
    assert r["hit"] and g.over and g.winner == "Jalen" and host.status()["game"]["word"] == "elephant"


def test_time_runs_out_and_no_key(tmp_path):
    host = GameHost(Ctrl(64), path=str(tmp_path / "g.json"))
    host.start("pictionary", {"word": "owl", "imaginer": FakeImaginer(), "seconds": 5})
    g = host.game
    wait_drawn(g)
    g._clock = lambda: g.t0 + 6.0
    host.frame_at(64)
    assert g.over and not g.won and g.message == "Time. It was a owl."
    assert "image key" in host.start("pictionary", {})["error"]


def test_the_picture_at_both_sizes(tmp_path):
    for size, scale in ((64, 4), (192, 2)):
        host = GameHost(Ctrl(size), path=str(tmp_path / "g.json"))
        host.start("pictionary", {"word": "elephant", "imaginer": FakeImaginer()})
        g = host.game
        wait_drawn(g)
        f = host.frame_at(size)
        assert f.shape == (size, size, 3) and f[size // 2, size // 2].mean() < 150      # the grey shape
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"pictionary-{size}.png"))
