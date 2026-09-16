"""Spelling Bee: a hive from the common words, scoring and ranks, spoken
words, the hive at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_spellingbee.py -q
"""
import os
import random
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.spellingbee import make_hive, score_of, rank_of   # noqa: E402
from brain.games.words import common                                             # noqa: E402
from brain.games.host import GameHost                                            # noqa: E402
from brain.tests.test_games import FakeCtrl                                      # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_hive_and_scores():
    centre, others, answers = make_hive(random.Random(1), common(4, 12))
    letters = set(centre + others)
    assert len(letters) == 7 and "s" not in letters and centre not in others
    assert 20 <= len(answers) <= 90 and all(centre in w and set(w) <= letters and len(w) >= 4 for w in answers)
    assert any(set(w) == letters for w in answers)                        # a pangram is in there
    assert score_of("abcd", letters) == 1 and score_of("abcde", letters) == 5
    pan = next(w for w in answers if set(w) == letters)
    assert score_of(pan, letters) == len(pan) + 7
    assert rank_of(0, 100) == "Beginner" and rank_of(70, 100) == "Genius" and rank_of(15, 100) == "Solid"


def test_play(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("spellingbee", {"seed": 1}, ["Jalen"])
    g = host.game
    word = g.answers[0]
    r = host.hear(word, "Jalen")
    assert r["word"] == word and r["points"] >= 1 and g.points == r["points"]
    assert host.hear(word, "Jalen")["error"] == "already found"
    assert host.hear("zzzz", "Jalen") is None                            # not from the hive: not a move
    short = g.centre * 3
    assert host.move("Jalen", {"word": short})["error"] == "four letters or more"
    no_centre = next((w for w in common(4, 8) if set(w) <= g.letters and g.centre not in w), None)
    if no_centre:
        assert "middle" in host.move("Jalen", {"word": no_centre})["error"]
    for w in g.answers[1:]:
        host.move("Jalen", {"word": w})
    assert g.over and g.won and g.message.startswith("Queen Bee")
    assert host.status()["game"]["answers"] == g.answers


def test_the_hive_at_both_sizes(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("spellingbee", {"seed": 2})
    g = host.game
    for w in g.answers[:3]:
        host.move(None, {"word": w})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        yellow = ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum()
        assert yellow > 40
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"spellingbee-{size}.png"))
