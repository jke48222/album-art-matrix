"""The pub quiz: bundled rounds, answers by voice from several players,
the timer that moves the round along, the scores, the face at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_quiz.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                  # noqa: E402
from brain.games import quiz                           # noqa: E402,F401
from brain.games.quiz import BUNDLED, SHOW_ANSWER_S    # noqa: E402
from brain.tests.test_games import FakeCtrl            # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def test_bundled_rounds():
    for theme, qs in BUNDLED:
        assert len(qs) == 10 and all(q and accept for q, accept in qs)


def test_a_round(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("quiz", {"set": 1, "seconds": 20}, ["Jalen", "Sam"])
    g = host.game
    clock = [0.0]
    g._clock = lambda: clock[0]
    g.t_q = 0.0
    st = host.status()["game"]
    assert st["question"].startswith("What is the capital") and st["phase"] == "question" and st["seconds_left"] == 20
    assert host.hear("canberra", "Jalen")["right"] is True
    assert host.hear("sydney", "Jalen")["error"] == "you have answered"
    r = host.hear("Sydney", "Sam")
    assert r["right"] is False and g.phase == "answer"                        # everyone answered: reveal
    assert host.status()["game"]["answer"] == "canberra"
    clock[0] += SHOW_ANSWER_S + 0.1
    st = host.status()["game"]
    assert st["number"] == 2 and st["phase"] == "question"
    clock[0] += 25.0                                                          # nobody answers: time moves on
    st = host.status()["game"]
    assert st["phase"] == "answer" and st["answer"] == "6"
    host.move(None, {"next": True})
    assert g.i == 2 and g.phase == "question"
    for _ in range(8):
        host.hear("mars", "Jalen")
        host.move(None, {"next": True})
        host.move(None, {"next": True})
    assert g.over and g.winner == "Jalen" and g.scores == {"Jalen": 2, "Sam": 0}
    assert host.status()["game"]["results"][0]["answer"] == "canberra"


def test_the_face_at_both_sizes(tmp_path):
    for size, scale in ((64, 4), (192, 2)):
        host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
        host.start("quiz", {"set": 0})
        f = host.frame_at(size)
        assert f.shape == (size, size, 3)
        assert ((f[..., 0] > 150) & (f[..., 1] > 130) & (f[..., 2] < 90)).sum() > 20    # the timer bar
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"quiz-{size}.png"))
