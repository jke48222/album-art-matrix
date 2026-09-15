"""Twenty questions: a scripted asker, yes by knock and no by whistle,
the guess, the twentieth question, the face at 64 and 192.

    .venv/bin/python -m pytest brain/tests/test_twentyq.py -q
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.games.host import GameHost                  # noqa: E402
from brain.games import twentyq                        # noqa: E402
from brain.tests.test_games import FakeCtrl            # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


class ScriptedAsker:
    ready = True
    model = "scripted"
    cost_usd = 0.0

    def __init__(self, turns):
        self.turns = list(turns)
        self.seen = []

    def _client_(self):
        raise AssertionError("not used")


def scripted(monkeypatch, turns):
    asker = ScriptedAsker(turns)
    def fake(a, history, salt=0.0):
        a.seen.append(list(history))
        return a.turns.pop(0) if a.turns else {"question": "Is it big?"}
    monkeypatch.setattr(twentyq, "ask_claude", fake)
    return asker


def test_knocks_and_whistles_answer(tmp_path, monkeypatch):
    asker = scripted(monkeypatch, [{"question": "Is it alive?"}, {"question": "Is it an animal?"},
                                   {"guess": "a cat"}])
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    st = host.start("twentyq", {"asker": asker})
    g = host.game
    assert st["game"]["question"] == "Is it alive?" and st["game"]["number"] == 1
    assert host.event("knock", {"t": 1.0}) is True and g.current == "Is it an animal?"
    assert host.event("whistle", {"kind": "up"}) is True and g.current == "Is it a cat?"
    assert st["game"]["is_guess"] is False and host.status()["game"]["is_guess"] is True
    assert asker.seen[-1] == [("Is it alive?", "yes"), ("Is it an animal?", "no")]
    assert host.hear("yes")["got_it"] and g.over and g.won and g.message == "a cat, in 3."


def test_twenty_and_out(tmp_path, monkeypatch):
    asker = scripted(monkeypatch, [{"question": f"Question {i}?"} for i in range(30)])
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    host.start("twentyq", {"asker": asker})
    g = host.game
    for i in range(20):
        r = host.move(None, {"answer": "no"})
    assert g.over and not g.won and "You win" in g.message
    assert "over" in host.move(None, {"answer": "no"})["error"]


def test_needs_claude(tmp_path):
    host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
    assert "Claude" in host.start("twentyq", {})["error"]


def test_the_face_at_both_sizes(tmp_path, monkeypatch):
    asker = scripted(monkeypatch, [{"question": "Does it live in the sea, in the deep parts, far from shore?"}])
    for size, scale in ((64, 4), (192, 2)):
        host = GameHost(FakeCtrl(), path=str(tmp_path / "g.json"))
        host.start("twentyq", {"asker": asker})
        f = host.frame_at(size)
        assert f.shape == (size, size, 3) and ((f[..., 0] > 200) & (f[..., 1] > 200)).sum() > 10
        if OUT:
            Image.fromarray(f).resize((size * scale, size * scale), Image.NEAREST).save(
                os.path.join(OUT, f"twentyq-{size}.png"))
