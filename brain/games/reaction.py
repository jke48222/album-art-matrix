"""Reaction knock.

The wall goes red. Some seconds later, green. Knock the frame the moment
it does: the milliseconds between are the score, in big digits on the
panel. Five rounds each; the best and the average at the end. A knock
while it is still red is a false start and costs the round. The phone
can tap instead of knocking, though the network adds a few milliseconds
the ear does not.

The knock is the ear's, timed on its own clock (brain/nowplaying/knock.py
hands every lone knock to the running game at once), so the number is
the knock's, not the moment the wall noticed it. Options: {"rounds": n}.
"""
from __future__ import annotations

import random
import time

from . import Game, register
from .board import (DIM, GREEN, INK, RED, WHITE, YELLOW, banner, blank, breathe, glow, header, mix,
                    text_centred, scale_for)

WAIT_MIN_S, WAIT_MAX_S = 2.0, 5.0
SHOW_S = 2.5                      # the number stays this long before the next round


@register
class ReactionKnock(Game):
    name = "reaction"
    title = "Reaction knock"
    blurb = "Red, then green: knock. The milliseconds on the panel. Five rounds."
    min_players = 1
    max_players = 6

    def setup(self):
        self.rng = random.Random(self.options.get("seed"))
        self.rounds = max(1, min(20, int(self.options.get("rounds", 5))))
        self.turn = 0                    # index into players
        self.times: dict[str, list[int | None]] = {p: [] for p in self.players}
        self.phase = "ready"             # ready | red | green | shown
        self.t_red = 0.0
        self.t_go = 0.0
        self.t_shown = 0.0
        self.last_ms: int | None = None
        self.message = f"{self.players[0]}: knock when it turns green. Say go."
        self._clock = time.monotonic

    def _now(self) -> float:
        return self._clock()

    # ---- the round -----------------------------------------------------------------------------
    def begin(self) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if self.phase in ("red", "green"):
            return {"error": "a round is on"}
        now = self._now()
        self.phase = "red"
        self.t_red = now
        self.t_go = now + self.rng.uniform(WAIT_MIN_S, WAIT_MAX_S)
        self.message = f"{self.players[self.turn]}: wait for green."
        self.changed()
        return {"phase": "red"}

    def knock_at(self, t: float, how: str = "knock") -> dict:
        if self.over:
            return {"error": "the game is over"}
        if self.phase == "red" or (self.phase == "green" and t < self.t_go):
            self._score(None, "Too soon.")
            return {"false_start": True}
        if self.phase != "green":
            return {"error": "not yet"}
        ms = int(round((t - self.t_go) * 1000))
        self._score(ms, f"{ms} ms.")
        return {"ms": ms, "how": how}

    def _score(self, ms: int | None, why: str):
        who = self.players[self.turn]
        self.times[who].append(ms)
        self.last_ms = ms
        self.phase = "shown"
        self.t_shown = self._now()
        self.turn = (self.turn + 1) % len(self.players)
        self.message = f"{who}: {why}"
        if all(len(v) >= self.rounds for v in self.times.values()):
            best = {p: min([x for x in v if x is not None], default=None) for p, v in self.times.items()}
            ranked = sorted((b, p) for p, b in best.items() if b is not None)
            if ranked:
                winner = ranked[0][1] if len(self.players) > 1 else None
                self.finish(won=True, winner=winner, message=f"Best {ranked[0][0]} ms, {ranked[0][1]}.")
            else:
                self.finish(won=False, message="All false starts.")
        else:
            self.changed()

    def tick(self):
        """Time moves the round along; called when drawing."""
        if self.over:
            return
        now = self._now()
        if self.phase == "red" and now >= self.t_go:
            self.phase = "green"
            self.changed()
        elif self.phase == "shown" and now - self.t_shown >= SHOW_S:
            self.begin()

    # ---- moves and events ----------------------------------------------------------------------
    def apply(self, move: dict, player: str) -> dict:
        if move.get("go") or move.get("start"):
            return self.begin()
        if move.get("tap"):
            return self.knock_at(self._now(), how="tap")
        return {"error": "go, or tap"}

    def hear(self, text: str, player: str) -> dict | None:
        if text.lower().strip(" .!") in ("go", "start", "ready", "again"):
            return self.begin()
        return None

    def event(self, kind: str, info: dict) -> bool:
        if kind == "knock":
            r = self.knock_at(float(info.get("t", self._now())))
            return "error" not in r
        return kind in ("double", "whistle")            # swallowed: nothing switches the wall off mid-game

    def state(self) -> dict:
        self.tick()
        return {"phase": self.phase, "turn": self.players[self.turn], "round": len(self.times[self.players[self.turn]]) + 1,
                "rounds": self.rounds, "last_ms": self.last_ms,
                "times": {p: v for p, v in self.times.items()},
                "best": {p: min([x for x in v if x is not None], default=None) for p, v in self.times.items()}}

    def voice_words(self) -> list[str]:
        return ["go", "again"]

    # ---- the wall --------------------------------------------------------------------------------
    def frame_at(self, size: int, t: float):
        self.tick()
        c = blank(size)
        s = scale_for(size)
        who = self.players[self.turn]
        if self.phase == "red":
            c[...] = mix((150, 20, 20), (110, 12, 12), breathe(t, 1.6))
            text_centred(c, "wait", size // 2, size // 2 - 4 * s, mix(WHITE, (150, 20, 20), 0.35), s)
        elif self.phase == "green":
            c[...] = (30, 150, 50)
            glow(c, size / 2, size / 2, size * 0.5, (120, 240, 140), 0.25)
            text_centred(c, "KNOCK", size // 2, size // 2 - 4 * s, WHITE, s)
        elif self.phase == "shown" or self.over:
            if self.last_ms is None:
                text_centred(c, "too", size // 2, size // 2 - 9 * s, RED, s)
                text_centred(c, "soon", size // 2, size // 2, RED, s)
            else:
                col = GREEN if self.last_ms < 250 else YELLOW if self.last_ms < 400 else RED
                label = str(self.last_ms)
                big_s = (4 if len(label) <= 3 else 3) * s
                text_centred(c, label, size // 2, size // 2 - 4 * big_s, col, big_s)
                text_centred(c, "ms", size // 2, size // 2 + 4 * big_s - 3 * s, DIM, s)
            if self.over:
                banner(c, size, self.message, INK, (40, 40, 44))
        else:
            text_centred(c, "KNOCK", size // 2, size // 2 - 8 * s, INK, s)
            text_centred(c, "on green", size // 2, size // 2 + 2 * s, DIM, s)
        header(c, size, "REACTION", f"{who} {len(self.times[who]) + 1}/{self.rounds}" if not self.over else "", s,
               accent=GREEN)
        return c

