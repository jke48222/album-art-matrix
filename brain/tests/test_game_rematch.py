"""The phone's "Play another round" sends {"again": true}. The wall must restart
with the same options and players, so a Sudoku rematch keeps its difficulty
and a two-phone game keeps both seats."""
import threading

from brain.games import arcade, sudoku  # noqa: F401  (registers pong and sudoku)
from brain.games.host import GameHost


class Wall:
    def __init__(self):
        self.mode = "art"
        self.shown_seq = 0
        self.dirty = threading.Event()
    def get(self): return {"mode": self.mode}
    def apply(self, patch): self.mode = patch.get("mode", self.mode)


def test_again_keeps_sudoku_difficulty_and_players(tmp_path):
    h = GameHost(Wall(), path=str(tmp_path / "games.json"))
    first = h.start("sudoku", {"difficulty": "easy", "seed": 3}, ["River"])
    assert first["game"]["rating"] == "easy"
    h.game.finish(True, None, "Solved")
    again = h.move("River", {"again": True}, first["session_id"])
    assert "error" not in again
    assert again["session_id"] != first["session_id"]
    assert again["game"]["players"] == ["River"]
    assert again["game"]["rating"] == "easy"
    assert h.game.options == {"difficulty": "easy", "seed": 3}


def test_again_keeps_both_players_in_order(tmp_path):
    h = GameHost(Wall(), path=str(tmp_path / "games.json"))
    first = h.start("pong", None, ["River", "Sol"])
    h.game.finish(True, "River", "River wins")
    again = h.move("Sol", {"again": True}, first["session_id"])
    assert "error" not in again
    assert again["game"]["players"] == ["River", "Sol"]


def test_again_from_a_stale_session_is_refused(tmp_path):
    h = GameHost(Wall(), path=str(tmp_path / "games.json"))
    first = h.start("sudoku", {"difficulty": "easy", "seed": 3}, ["River"])
    h.game.finish(True, None, "Solved")
    second = h.move("River", {"again": True}, first["session_id"])
    h.game.finish(True, None, "Solved")
    # A second phone still showing the first round must not restart the new one.
    late = h.move("River", {"again": True}, first["session_id"])
    assert late["code"] == 409 and late["session_id"] == second["session_id"]
