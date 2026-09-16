"""The games shell and Wordle: the host, the scores on disk, the mode
handshake, marks with repeated letters, spoken guesses, the board at 64
and 192.

    .venv/bin/python -m pytest brain/tests/test_games.py -q
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                          # noqa: E402
from brain.games.wordle import mark                    # noqa: E402
from brain.games.words import answers5, valid5, common         # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


class Event:
    def __init__(self):
        self.flag = False
    def set(self):
        self.flag = True


class FakeCtrl:
    def __init__(self):
        self.s = {"mode": "art"}
        self.dirty = Event()
        self.shown_seq = 0
        self.applied = []
    def get(self):
        return dict(self.s)
    def apply(self, p):
        self.s.update(p)
        self.applied.append(p)
        return {}


def test_word_lists_are_there():
    assert len(answers5()) >= 2000 and all(len(w) == 5 for w in answers5())
    assert "crane" in valid5() and "zzzzz" not in valid5()
    assert len(common()) > 20000 and common()[0] in ("you", "the", "and", "that")


def test_marks_with_repeated_letters():
    assert mark("crane", "crane") == "ggggg"
    assert mark("speed", "abide") == "xxyxy"      # one e spare, the first unplaced e gets it... then d
    assert mark("eerie", "there") == "yxyxg"      # one e green at the end, one yellow, the r yellow
    assert mark("allee", "nasal") == "yyxxx"
    assert mark("robot", "boost") == "xgyyg"


def test_a_game_runs_end_to_end(tmp_path):
    ctrl = FakeCtrl()
    host = GameHost(ctrl, path=str(tmp_path / "games.json"), clock=lambda: 100.0)
    assert any(g["name"] == "wordle" for g in host.listing())
    st = host.start("wordle", {"word": "crane"}, ["Jalen"])
    assert st["running"] and st["game"]["title"] == "Wordle" and ctrl.s["mode"] == "game"
    assert st["game"]["answer"] is None and "crane" in st["voice_words"]
    r = host.move("Jalen", {"guess": "zzzzz"})
    assert r["error"] and r["game"]["guesses_left"] == 6              # not a word, not counted
    r = host.hear("guess slate", "Jalen")
    assert r["marks"] == "xxgxg" and r["game"]["guesses_left"] == 5 and r["game"]["rows"][0]["word"] == "slate"
    assert host.hear("what time is it", "Jalen") is None              # not a move
    seq = host.seq
    r = host.hear("crane", "Jalen")
    assert r["marks"] == "ggggg" and r["game"]["over"] and r["game"]["won"] and r["game"]["answer"] == "crane"
    assert r["game"]["message"] == "Magnificent." and host.seq > seq
    assert host.scores("wordle")["Jalen"] == {"played": 1, "won": 1, "streak": 1, "best": 1,
                                             "last": host.scores("wordle")["Jalen"]["last"]}
    assert host.move("Jalen", {"guess": "crane"})["error"] == "that game is over"
    ended = host.end()
    assert ended["ended"] and ctrl.s["mode"] == "art" and not host.status()["running"]
    again = GameHost(ctrl, path=str(tmp_path / "games.json"))
    assert again.scores("wordle")["Jalen"]["won"] == 1
    # a lost game, then an abandoned one, break the streak
    host.start("wordle", {"word": "crane"}, ["Jalen"])
    for w in ("slate", "slate", "slate", "slate", "slate", "slate"):
        host.move("Jalen", {"guess": w})
    assert host.game.over and not host.game.won and host.scores("wordle")["Jalen"]["streak"] == 0
    host.start("wordle", {"seed": 3}, ["Jalen", "Sam"])
    assert host.game.players == ["Jalen", "Sam"] and host.game.turn == 0
    host.move("Sam", {"guess": "crane"})
    assert host.game.turn == 1 or host.game.over
    host.start("wordle", {"seed": 4})                                 # abandons the last
    assert host.scores("wordle")["Jalen"]["played"] == 3              # won, lost, abandoned


def test_the_board_at_both_sizes(tmp_path):
    ctrl = FakeCtrl()
    host = GameHost(ctrl, path=str(tmp_path / "games.json"))
    host.start("wordle", {"word": "crane"})
    for w in ("slate", "ocean", "cramp"):
        host.move(None, {"guess": w})
    for size, scale in ((64, 4), (192, 2)):
        f = host.frame_at(size)
        assert f.shape == (size, size, 3) and f.dtype == np.uint8
        greens = ((f[..., 1] > 130) & (f[..., 0] < 100)).sum()
        yellows = ((f[..., 0] > 170) & (f[..., 1] > 150) & (f[..., 2] < 80)).sum()
        assert greens > 50 and yellows > 20
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"wordle-{size}.png"))
    host.end()
    idle = host.frame_at(64)
    assert idle.max() > 0                                             # the scoreboard face
