"""A note is passing through. Anything that takes the wall while a note is
up (a picture shown by name, a drawing, a game, the HomeKit pairing code)
must hand back the face the note will return to, never the note's own
"ticker": a note that came back that way would have no expiry and no Take
down (ControlState.resting_face).

    .venv/bin/python -m pytest brain/tests/test_note_return_faces.py -q
"""
from types import SimpleNamespace

import numpy as np
import pytest

from brain.control import ControlState
from brain.games import wordle                      # noqa: F401  (registers the game)
from brain.games.host import GameHost
from brain.homekit import HomeKit
from brain.imagine import Imaginer
from brain.show import Shower

URI = "X-HM://0023ISYWY7OSY"  # Authored test data, never a real wall credential.


@pytest.fixture
def no_timers(monkeypatch):
    """Notes and pictures set threading.Timers. These never fire."""
    class Timer:
        def __init__(self, interval, callback, args=None, kwargs=None):
            self.daemon = True
        def start(self):
            pass
        def cancel(self):
            pass
    monkeypatch.setattr("brain.control.threading.Timer", Timer)


def noted(face="clock"):
    ctrl = ControlState()
    ctrl.apply({"mode": face, "ticker_text": "Mine"})
    ctrl.note("Back at seven", 30)
    assert ctrl.get()["mode"] == "ticker" and ctrl.resting_face() == face
    return ctrl


def settled(ctrl, face="clock"):
    state = ctrl.get()
    assert state["mode"] == face
    assert not ctrl.note_status()["active"]
    assert state["ticker_text"] == "Mine"          # the owner's words, not the note


def test_a_picture_shown_over_a_note_hands_back_the_notes_face(no_timers):
    ctrl = noted()
    shower = Shower(ctrl)
    assert shower.show_frame(np.zeros((64, 64, 3), np.uint8), 60)
    assert ctrl.get()["mode"] == "frame" and shower._ret == "clock"
    shower._until = 0.0                            # its time is up
    shower._take_down(shower._frame_seq)
    settled(ctrl)


def test_a_drawing_over_a_note_hands_back_the_notes_face(no_timers, tmp_path):
    ctrl = noted()
    im = Imaginer(ctrl, path=str(tmp_path / "imagined"))
    im._go_live("a purple elephant")
    assert ctrl.get()["mode"] == "imagine" and im._ret == "clock"
    im.release()
    settled(ctrl)


def test_a_note_over_a_drawing_keeps_the_drawings_own_return(no_timers, tmp_path):
    ctrl = ControlState()
    ctrl.apply({"mode": "cd"})
    im = Imaginer(ctrl, path=str(tmp_path / "imagined"))
    im._go_live("a purple elephant")
    ctrl.note("Back at seven", 30)                 # returns to "imagine"
    im._go_live("a green one", quick=True)         # shown again over the note
    assert im._ret == "cd"
    im.release()
    assert ctrl.get()["mode"] == "cd"


def test_a_game_started_over_a_note_hands_back_the_notes_face(no_timers, tmp_path):
    ctrl = noted()
    host = GameHost(ctrl, path=str(tmp_path / "games.json"), clock=lambda: 100.0)
    assert host.start("wordle", {"word": "crane"}, ["You"])["running"]
    assert ctrl.get()["mode"] == "game" and host._ret == "clock"
    host.end()
    settled(ctrl)


def test_a_game_resumed_over_a_note_hands_back_the_notes_face(no_timers, tmp_path):
    ctrl = ControlState()
    ctrl.apply({"mode": "clock", "ticker_text": "Mine"})
    host = GameHost(ctrl, path=str(tmp_path / "games.json"), clock=lambda: 100.0)
    host.start("wordle", {"word": "crane"}, ["You"])
    ctrl.apply({"mode": "cd"})                     # the game parked
    ctrl.note("Back at seven", 30)                 # returns to "cd"
    host.resume()
    assert ctrl.get()["mode"] == "game" and host._ret == "cd"
    host.end()
    settled(ctrl, "cd")


def test_a_note_over_a_game_keeps_the_games_own_return(no_timers, tmp_path):
    ctrl = ControlState()
    ctrl.apply({"mode": "clock", "ticker_text": "Mine"})
    host = GameHost(ctrl, path=str(tmp_path / "games.json"), clock=lambda: 100.0)
    host.start("wordle", {"word": "crane"}, ["You"])
    ctrl.note("Back at seven", 30)                 # returns to "game"
    host.resume()
    assert host._ret == "clock"
    host.end()
    settled(ctrl)


def test_the_pairing_code_over_a_note_hands_back_the_notes_face(no_timers):
    ctrl = noted()
    hk = HomeKit(ctrl)
    hk.driver = SimpleNamespace(state=SimpleNamespace(paired=False, pincode=b"031-45-154"),
                                config_changed=lambda: None)
    hk.bridge = SimpleNamespace(xhm_uri=lambda: URI)
    hk.ready.set()
    assert hk.show_code(60)
    assert ctrl.get()["mode"] == "frame" and hk._code_ret == "clock"
    hk.hide_code()
    settled(ctrl)


def test_a_note_over_a_picture_does_not_replace_the_pictures_own_return(no_timers):
    ctrl = ControlState()
    ctrl.apply({"mode": "clock"})
    shower = Shower(ctrl)
    assert shower.show_frame(np.zeros((64, 64, 3), np.uint8), 60)
    ctrl.note("Back at seven", 30)                 # rests on the picture's frame
    assert shower.show_frame(np.ones((64, 64, 3), np.uint8), 60)
    assert shower._ret == "clock"


def test_a_note_over_the_pairing_code_keeps_the_codes_own_return(no_timers):
    ctrl = ControlState()
    ctrl.apply({"mode": "clock"})
    hk = HomeKit(ctrl)
    hk.driver = SimpleNamespace(state=SimpleNamespace(paired=False, pincode=b"031-45-154"),
                                config_changed=lambda: None)
    hk.bridge = SimpleNamespace(xhm_uri=lambda: URI)
    hk.ready.set()
    assert hk.show_code(60)
    ctrl.note("Back at seven", 30)
    assert hk.show_code(60)
    assert hk._code_ret == "clock"


def test_whether_the_message_had_its_own_ink_survives_a_restart(tmp_path, monkeypatch):
    monkeypatch.setattr("brain.control.STATE_PATH", str(tmp_path / "state.json"))
    ctrl = ControlState()
    ctrl.apply({"mode": "ticker", "ticker_text": "Mine", "ticker_color": "#112233"})
    assert ctrl.ticker_own_ink() == "#112233"
    assert ControlState().ticker_own_ink() == "#112233"
    ctrl.note("Back at seven", 30)                 # a note carries no ink of its own
    ctrl.apply({"brightness": 0.5})                # any later save
    assert ControlState().ticker_own_ink() is None


def test_state_reports_the_ink_the_message_is_drawn_in():
    ctrl = ControlState()
    ctrl.apply({"mode": "ticker", "ticker_text": "Mine", "ticker_color": "#112233"})
    assert ctrl.public_state()["ticker_ink"] == "#112233"
    ctrl.apply({"ticker_text": "No ink of its own"})
    assert ctrl.public_state()["ticker_ink"] is None
    assert ctrl.public_state()["ticker_color"] == "#112233"   # still the editor's colour
