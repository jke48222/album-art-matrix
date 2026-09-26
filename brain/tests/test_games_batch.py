"""Game transitions remain responsive and reject stale ownership receipts."""
import threading
from concurrent.futures import ThreadPoolExecutor

import numpy as np
import pytest

from brain.games import GAMES, Game
from brain.games.host import GameHost


class Wall:
    def __init__(self, mode="art"):
        self.mode = mode
        self.shown_seq = 0
        self.dirty = threading.Event()
        self.applied = []
    def get(self): return {"mode": self.mode}
    def apply(self, patch):
        self.mode = patch.get("mode", self.mode)
        self.applied.append(dict(patch))


class TestPuzzle(Game):
    __test__ = False
    name = "test-puzzle"
    title = "Test puzzle"
    max_players = 2
    def setup(self): self.moves = []
    def apply(self, move, player):
        self.moves.append((dict(move), player))
        if move.get("finish"): self.finish(True, player, "Solved")
        return {"accepted": True}
    def hear(self, text, player): return self.apply({"heard": text}, player)
    def event(self, kind, info):
        if kind == "finish": self.finish(True, self.players[0], "Solved by the room")
        return kind == "finish"
    def state(self): return {"moves": list(self.moves)}
    def frame_at(self, size, t):
        if self.options.get("finish_in_frame") and not self.over: self.finish(True, self.players[0], "Time complete")
        return np.zeros((size, size, 3), np.uint8)


@pytest.fixture
def game_host(tmp_path, monkeypatch):
    monkeypatch.setitem(GAMES, TestPuzzle.name, TestPuzzle)
    return GameHost(Wall(), path=str(tmp_path / "games.json"))


def blocking_game(monkeypatch, *, failure=False):
    started, finish = threading.Event(), threading.Event()
    class Preparing(TestPuzzle):
        name = "preparing"
        title = "Preparing puzzle"
        def setup(self):
            super().setup()
            started.set()
            assert finish.wait(3), "test did not release setup"
            if failure: raise RuntimeError("provider failed")
    monkeypatch.setitem(GAMES, Preparing.name, Preparing)
    return started, finish


def test_failed_setup_preserves_running_game_and_ledger(game_host, monkeypatch):
    h = game_host
    old = h.start(TestPuzzle.name)
    h.move(None, {"step": 1}, old["session_id"])
    class Broken(TestPuzzle):
        name = "broken"
        def setup(self): raise RuntimeError("network unreachable")
    monkeypatch.setitem(GAMES, Broken.name, Broken)
    result = h.start(Broken.name, session_id=old["session_id"])
    assert result["code"] == 502
    assert result["session_id"] == old["session_id"]
    assert result["game"]["moves"] == [({"step": 1}, "You")]
    assert h.ctrl.mode == "game" and h.scores(TestPuzzle.name) == {}
    assert result["starting"] is None


def test_simultaneous_start_rejects_second_and_status_stays_responsive(game_host, monkeypatch):
    started, finish = blocking_game(monkeypatch)
    with ThreadPoolExecutor(max_workers=3) as pool:
        first = pool.submit(game_host.start, "preparing")
        assert started.wait(2)
        status = pool.submit(game_host.status).result(timeout=1)
        assert status["starting"] == "preparing" and not status["running"]
        second = pool.submit(game_host.start, TestPuzzle.name).result(timeout=1)
        assert second["code"] == 409
        finish.set()
        result = first.result(timeout=2)
    assert result["game"]["name"] == "preparing" and result["on_wall"]


@pytest.mark.parametrize("has_old_game", [False, True])
def test_end_cancels_pending_setup_and_never_resurrects_it(game_host, monkeypatch, has_old_game):
    if has_old_game: game_host.start(TestPuzzle.name)
    started, finish = blocking_game(monkeypatch)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(game_host.start, "preparing")
        assert started.wait(2)
        ended = pool.submit(game_host.end).result(timeout=1)
        assert not ended["running"] and ended["starting"] is None
        finish.set()
        assert pending.result(timeout=2)["code"] == 409
    assert game_host.ctrl.mode == "art" and game_host.game is None


@pytest.mark.parametrize("change", ["mode", "content"])
def test_changed_wall_while_loading_keeps_user_choice(game_host, monkeypatch, change):
    started, finish = blocking_game(monkeypatch)
    with ThreadPoolExecutor(max_workers=1) as pool:
        pending = pool.submit(game_host.start, "preparing")
        assert started.wait(2)
        if change == "mode": game_host.ctrl.apply({"mode": "off"})
        else: game_host.ctrl.shown_seq += 1
        finish.set()
        result = pending.result(timeout=2)
    assert result["code"] == 409 and not result["running"]
    assert game_host.ctrl.mode == ("off" if change == "mode" else "art")


@pytest.mark.parametrize("action", ["move", "hear", "end", "start", "resume"])
def test_stale_session_cannot_change_replacement_game(game_host, action):
    h = game_host
    old = h.start(TestPuzzle.name)["session_id"]
    fresh = h.start(TestPuzzle.name, session_id=old)["session_id"]
    before = h.seq
    if action == "move": result = h.move(None, {"finish": True}, old)
    elif action == "hear": result = h.hear("finish", session_id=old)
    elif action == "end": result = h.end(old)
    elif action == "start": result = h.start(TestPuzzle.name, session_id=old)
    else: result = h.resume(old)
    assert result["code"] == 409 and result["session_id"] == fresh
    assert not h.game.over and h.game.moves == [] and h.seq == before


@pytest.mark.parametrize("finish_by", ["move", "event", "frame", "status"])
def test_finished_game_is_recorded_once_across_render_status_end_and_replacement(game_host, finish_by):
    h = game_host
    st = h.start(TestPuzzle.name, {"finish_in_frame": finish_by == "frame"}, ["River"])
    if finish_by == "move": h.move("River", {"finish": True}, st["session_id"])
    elif finish_by == "event": assert h.event("finish", {})
    elif finish_by == "frame": h.frame_at(64)
    else: h.game.finish(True, "River", "Finished externally")
    for _ in range(3):
        h.status(); h.frame_at(64)
    assert h.scores(TestPuzzle.name)["River"]["played"] == 1
    assert h.scores(TestPuzzle.name)["River"]["won"] == 1
    h.end(st["session_id"])
    assert h.scores(TestPuzzle.name)["River"]["played"] == 1
    h.start(TestPuzzle.name, players=["River"])
    assert h.scores(TestPuzzle.name)["River"]["played"] == 1


def test_end_preserves_explicit_off_and_counts_abandonment_once(game_host):
    h = game_host
    sid = h.start(TestPuzzle.name)["session_id"]
    h.ctrl.apply({"mode": "off"})
    assert h.end(sid)["ended"]
    assert h.ctrl.mode == "off"
    assert not h.end()["ended"]
    assert h.scores(TestPuzzle.name)["You"]["played"] == 1


def test_status_does_not_resume_hidden_game_but_explicit_resume_does(game_host):
    h = game_host
    sid = h.start(TestPuzzle.name)["session_id"]
    h.ctrl.apply({"mode": "off"})
    assert not h.status()["on_wall"] and h.ctrl.mode == "off"
    result = h.resume(sid)
    assert result["on_wall"] and result["session_id"] == sid and h.ctrl.mode == "game"
    h.end(sid)
    assert h.ctrl.mode == "off"


def test_starting_from_off_returns_to_off_on_end(game_host):
    h = game_host
    h.ctrl.apply({"mode": "off"})
    sid = h.start(TestPuzzle.name)["session_id"]
    h.end(sid)
    assert h.ctrl.mode == "off"


def test_play_again_does_not_hold_move_lock_during_provider_setup(game_host, monkeypatch):
    h = game_host
    started, finish = blocking_game(monkeypatch)
    finish.set()
    sid = h.start("preparing")["session_id"]
    h.game.finish(True, "You")
    started.clear(); finish.clear()
    with ThreadPoolExecutor(max_workers=3) as pool:
        pending = pool.submit(h.move, None, {"again": True}, sid)
        assert started.wait(2)
        status = pool.submit(h.status).result(timeout=1)
        assert status["starting"] == "preparing"
        ended = pool.submit(h.end, sid).result(timeout=1)
        assert ended["ended"]
        finish.set()
        assert pending.result(timeout=2)["code"] == 409
    assert h.game is None and h.ctrl.mode == "art"


def test_player_names_are_normalized_and_deduplicated(game_host):
    result = game_host.start(TestPuzzle.name, players=[" River ", "River", " ", "Sol"])
    assert result["game"]["players"] == ["River", "Sol"]


def test_invalid_start_input_preserves_current_game(game_host):
    sid = game_host.start(TestPuzzle.name)["session_id"]
    for fields in ({"options": []}, {"players": "River"}, {"players": [None]}):
        result = game_host.start(TestPuzzle.name, session_id=sid, **fields)
        assert result["code"] == 400 and result["session_id"] == sid
