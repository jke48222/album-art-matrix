"""Games on the wall.

The wall is the board and the phone is the hand: every game draws itself
at 64 and at 192, takes its moves from the phone (touch, or the phone's
own speech recogniser primed with the game's words) or from the wall's
ears, and keeps its state as JSON the phone polls. One game runs at a
time, held by the GameHost (brain/games/host.py); the wall is in mode
"game" while it does and goes back to what it was doing after.

A game is a class registered here:

    @register
    class Wordle(Game):
        name = "wordle"; title = "Wordle"
        def setup(self): ...          # a fresh puzzle
        def apply(self, move, player): ...   # {"guess": "crane"} -> a result
        def hear(self, text, player): ...    # speech -> a move, or None
        def state(self): ...          # what the phone draws
        def frame_at(self, size, t): ...     # what the wall draws
"""
from __future__ import annotations

import time

import numpy as np

GAMES: dict[str, type["Game"]] = {}


def register(cls):
    GAMES[cls.name] = cls
    return cls


class Game:
    name = "game"
    title = "A game"
    blurb = ""
    min_players = 1
    max_players = 1
    by_voice = True                 # moves can be spoken

    def __init__(self, host, options: dict | None = None, players: list[str] | None = None):
        self.host = host
        self.options = dict(options or {})
        self.players = list(players or ["You"])
        self.over = False
        self.won = False            # a puzzle solved; for a contest, see winner
        self.winner: str | None = None
        self.message = ""           # one line for the phone and the wall
        self.started = time.time()
        self.finished: float | None = None
        self.seq = 0

    # ---- what a game fills in ----------------------------------------------------------
    def setup(self):
        """A fresh puzzle. Options may ask for a particular one."""

    def apply(self, move: dict, player: str) -> dict:
        return {"error": "this game takes no moves"}

    def hear(self, text: str, player: str) -> dict | None:
        """Speech to a move: the result of apply, or None when the words
        are not a move in this game (the wall then treats them as anything
        else it hears)."""
        return None

    def state(self) -> dict:
        return {}

    def frame_at(self, size: int, t: float) -> np.ndarray:
        return np.zeros((size, size, 3), dtype=np.uint8)

    def voice_words(self) -> list[str]:
        """Words the phone's speech recogniser should expect."""
        return []

    # ---- shared ------------------------------------------------------------------------
    def public(self) -> dict:
        return {"name": self.name, "title": self.title, "players": self.players, "over": self.over,
                "won": self.won, "winner": self.winner, "message": self.message,
                "started": int(self.started), "finished": int(self.finished) if self.finished else None,
                "seq": self.seq, "voice": self.by_voice, **self.state()}

    def finish(self, won: bool = False, winner: str | None = None, message: str | None = None):
        self.over, self.won, self.winner = True, won, winner
        self.finished = time.time()
        if message is not None:
            self.message = message
        self.changed()

    def changed(self):
        self.seq += 1
        if self.host is not None:
            self.host.changed()

    @classmethod
    def describe(cls) -> dict:
        return {"name": cls.name, "title": cls.title, "blurb": cls.blurb,
                "players": [cls.min_players, cls.max_players], "voice": cls.by_voice}
