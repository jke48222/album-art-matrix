"""Follow-ups to the second review wave: the ticker's own ink and pace in
the render loop, the voice's Show me switch, and the phone's poster lookup
giving way to the Mac's.

    .venv/bin/python -m pytest brain/tests/test_brain_followups.py -q
"""
import threading
from types import SimpleNamespace

import pytest

from brain.features import Features
from brain.posters import Posters
from brain.tests.test_rest_batch import running_wall            # noqa: F401  (fixture)
from brain.voice.commands import Command
from brain.voice.voice import Voice


# ---- the render loop draws the ticker in its own ink and pace ---------------

def test_the_loop_inks_a_message_its_own_and_a_note_with_the_album(running_wall, monkeypatch):
    from brain import main as runtime
    built = []

    class Recorder(runtime.Ticker):
        def __init__(self, size, text, **kwargs):
            built.append((text, kwargs["color"], kwargs["speed"]))
            super().__init__(size, text, **kwargs)
    monkeypatch.setattr(runtime, "Ticker", Recorder)
    ctrl, wait = running_wall.ctrl, running_wall.wait
    ctrl.art_colors = ("#abcdef", "#123456")
    ctrl.apply({"color": "#4060ff", "speed": 0.5, "match_art": True})
    ctrl.apply({"mode": "ticker", "ticker_text": "Hi there", "ticker_color": "#112233",
                "ticker_speed": 2})
    wait(lambda: ("Hi there", "#112233", 2.0) in built)
    # A note brings no ink: Match Art still inks it with the album, at the
    # ticker's pace. The lamp's color and speed are for the lamp.
    ctrl.note("Back soon", 30)
    wait(lambda: any(text == "Back soon" for text, _, _ in built))
    assert [(c, s) for text, c, s in built if text == "Back soon"][-1] == ("#abcdef", 2.0)


# ---- the voice asks the Show me switch for show and play --------------------

class Shower:
    def __init__(self):
        self.calls = []

    def show(self, words, kind="any"):
        self.calls.append(("show", words))
        return {"shown": True}

    def play(self, words):
        self.calls.append(("play", words))
        return {"playing": True}

    def earworm(self, words):
        self.calls.append(("earworm", words))
        return {"shown": True}


def spoken(features):
    ctrl = SimpleNamespace(features=Features({"features": features}), dirty=threading.Event(),
                           transition=None)
    shower = Shower()
    return Voice(ctrl, wake=None, transcriber=None, shower=shower, log=lambda s: None), shower


@pytest.mark.parametrize("name", ["show", "play"])
def test_show_and_play_are_refused_when_show_me_is_off(name):
    # The shower is built for earworm or imagine, so it is there all the same.
    voice, shower = spoken({"show": False, "earworm": True})
    voice._do(Command(name, query="the Eiffel Tower"))
    assert voice.last_answer == "Show me is off on this wall."
    assert shower.calls == []
    voice._do(Command("earworm", words="I can't stop the feeling"))
    assert shower.calls == [("earworm", "I can't stop the feeling")]


def test_show_and_play_run_when_show_me_is_on():
    voice, shower = spoken({})
    voice._do(Command("show", query="the Eiffel Tower"))
    voice._do(Command("play", query="the Gameboy video"))
    assert shower.calls == [("show", "the Eiffel Tower"), ("play", "the Gameboy video")]
    assert voice.last_answer is None


# ---- the phone's poster lookup gives way to the Mac's -----------------------

SEVERANCE = {"results": [{"id": 95396, "name": "Severance", "first_air_date": "2022-02-17",
                          "poster_path": "/lFf6LLrQjYldcZItygKkKUtbdP.jpg"}]}
OPPENHEIMER = {"results": [{"id": 872585, "title": "Oppenheimer", "release_date": "2023-07-19",
                            "poster_path": "/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg"}]}


def test_a_later_mac_lookup_clears_the_phones_checked_result(tmp_path):
    table = {("/search/tv", "severance"): SEVERANCE, ("/search/movie", "oppenheimer"): OPPENHEIMER}
    clock = [1_760_000_000.0]
    posters = Posters(api_key="0123456789abcdef0123456789abcdef", path=str(tmp_path / "p.json"),
                      fetch=lambda path, params: table.get((path, params["query"].lower()), {"results": []}),
                      clock=lambda: clock[0])
    posters.lookup("Severance", force=True)                 # the phone's Look up title
    assert posters.status()["checked"]["title"] == "Severance"
    clock[0] += 10
    posters.lookup("Oppenheimer (2023) - Prime Video")       # the Mac, a moment later
    status = posters.status()
    assert status["state"] == "matched" and status["last"]["title"] == "Oppenheimer"
    assert status["checked"] is None
