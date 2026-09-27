"""Reaction knock: one authoritative monotonic clock, one score per turn.

Knock timestamps come from the wall's detector. Phone taps are timed when
received and include display, input and network delay; they are never presented
as a calibrated measurement of a person's reaction speed.
"""
from __future__ import annotations

import math
import random
import time

from . import Game, register
from .board import blank, disc, fill, rect, ring, text_centred
from .parking import parked
from ..art.pixelfont import text_width

WAIT_MIN_S, WAIT_MAX_S = 2.0, 5.0
SHOW_S = 2.5
RESPONSE_LIMIT_S = 30.0
COLOURS = {"ground": (11, 10, 9), "quiet": (31, 34, 32), "line": (93, 111, 103),
           "ready": (189, 214, 180), "red": (85, 29, 26), "red_ink": (255, 192, 173),
           "green": (35, 108, 74), "green_ink": (216, 255, 220), "white": (255, 255, 255),
           "dim": (162, 164, 150), "error": (236, 105, 89)}


def finite_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


@register
class ReactionKnock(Game):
    name = "reaction"
    title = "Reaction knock"
    blurb = "Wait for the signal. Knock the wall or tap the phone. Find your rhythm in five rounds."
    min_players = 1
    max_players = 6

    def setup(self):
        rounds = self.options.get("rounds", 5)
        if type(rounds) is not int or not 1 <= rounds <= 20:
            raise ValueError("Choose 1 to 20 reaction rounds.")
        self.rng = random.Random(self.options.get("seed"))
        self.rounds = rounds
        self.turn = 0
        self.times: dict[str, list[int | None]] = {p: [] for p in self.players}
        self.trials: dict[str, list[dict]] = {p: [] for p in self.players}
        self.phase = "ready"
        self.t_red = self.t_go = self.t_shown = 0.0
        self.last_ms: int | None = None
        self.last_kind = "ready"
        self.last_how: str | None = None
        self.last_player: str | None = None
        self.last_round = 0
        self.message = "Start when everyone is ready. Wait for NOW, then knock or tap."
        self._clock = time.monotonic

    def _now(self):
        value = self._clock()
        return float(value) if finite_number(value) and value >= 0 else None

    def begin(self):
        if self.over:
            return {"error": "This game is complete. Start another round from the results."}
        if self.phase != "ready":
            return {"error": "This round is already underway. The next turn starts automatically."}
        now = self._now()
        if now is None:
            return {"error": "The wall’s timer is unavailable. Try again."}
        self.phase = "red"
        self.t_red, self.t_go = now, now + self.rng.uniform(WAIT_MIN_S, WAIT_MAX_S)
        self.message = f"{self.players[self.turn]}: wait for NOW."
        self.changed()
        return {"phase": "red"}

    def knock_at(self, t, how="knock"):
        if self.over:
            return {"error": "This game is complete."}
        if self.phase not in ("red", "green"):
            return {"error": "Wait for a round to begin."}
        now = self._now()
        if not finite_number(t) or t < 0 or now is None or t > now + 0.05 or t < self.t_red:
            return {"error": "That timing sample does not belong to this round."}
        if how not in ("knock", "tap"):
            return {"error": "Use a wall knock or a phone tap."}
        # Rendering is not the clock. A detector event can arrive after t_go
        # before frame_at has had a chance to change the cached phase to green.
        if t < self.t_go:
            self._score(None, "false_start", how, "Too soon. Wait for the next signal.")
            return {"false_start": True}
        elapsed = t - self.t_go
        if elapsed > RESPONSE_LIMIT_S:
            self._score(None, "missed", how, "No response this round.")
            return {"missed": True}
        ms = int(round(elapsed * 1000))
        self._score(ms, "hit", how, f"{ms} ms.")
        return {"ms": ms, "how": how}

    def _score(self, ms, kind, how, message):
        who = self.players[self.turn]
        if self.over or len(self.times[who]) >= self.rounds:
            return
        self.times[who].append(ms)
        self.trials[who].append({"ms": ms, "kind": kind, "how": how})
        self.last_ms, self.last_kind, self.last_how = ms, kind, how
        self.last_player, self.last_round = who, len(self.times[who])
        self.phase, self.t_shown = "shown", self._now() or self.t_go
        self.message = f"{who}: {message}"
        if all(len(values) >= self.rounds for values in self.times.values()):
            best = {p: min((x for x in values if x is not None), default=None) for p, values in self.times.items()}
            ranked = sorted((value, p) for p, value in best.items() if value is not None)
            tied = [p for value, p in ranked if value == ranked[0][0]] if ranked else []
            self.finish(won=bool(ranked), winner=tied[0] if len(tied) == 1 and len(self.players) > 1 else None,
                        message=f"Best {ranked[0][0]} ms." if ranked else "No turns scored.")
            return
        for offset in range(1, len(self.players) + 1):
            next_turn = (self.turn + offset) % len(self.players)
            if len(self.times[self.players[next_turn]]) < self.rounds:
                self.turn = next_turn
                break
        self.changed()

    def tick(self):
        if self.over:
            return
        now = self._now()
        if now is None:
            return
        if parked(self):
            # The phone keeps polling a parked game, but its board is off and
            # the host drops knocks, so nobody can answer. Hand the live turn
            # back unscored, and do not begin the next one on its own.
            if self.phase in ("red", "green") or (self.phase == "shown" and now - self.t_shown >= SHOW_S):
                self.phase = "ready"
                self.message = f"{self.players[self.turn]}: start when you're ready."
                self.changed()
            return
        if self.phase in ("red", "green") and now - self.t_go > RESPONSE_LIMIT_S:
            self._score(None, "missed", "none", "No response this round.")
        elif self.phase == "red" and now >= self.t_go:
            self.phase = "green"
            self.message = "NOW. Knock the wall or tap."
            self.changed()
        elif self.phase == "shown" and now - self.t_shown >= SHOW_S:
            self.phase = "ready"
            self.begin()

    def apply(self, move, player):
        if not isinstance(move, dict) or len(move) != 1:
            return {"error": "Start a round or tap once."}
        if (set(move) == {"go"} and move["go"] is True) or (set(move) == {"start"} and move["start"] is True):
            return self.begin()
        if set(move) == {"tap"} and move["tap"] is True:
            now = self._now()
            return self.knock_at(now, "tap")
        return {"error": "Start a round or tap once."}

    def hear(self, spoken, player):
        if isinstance(spoken, str) and spoken.lower().strip(" .!") in ("go", "start", "ready"):
            return self.begin()
        return None

    def event(self, kind, info):
        if self.over:
            return False
        if kind == "knock":
            if not isinstance(info, dict):
                return False
            return "error" not in self.knock_at(info.get("t", self._now()))
        return kind in ("double", "whistle")

    def state(self):
        self.tick()
        turn = self.last_player if self.over else self.players[self.turn]
        round_number = self.last_round if self.over else min(self.rounds, len(self.times[turn]) + 1)
        values = {p: [x for x in scores if x is not None] for p, scores in self.times.items()}
        return {"phase": self.phase, "turn": turn, "round": round_number, "rounds": self.rounds,
                "last_ms": self.last_ms, "last_kind": self.last_kind, "last_how": self.last_how,
                "last_player": self.last_player, "last_round": self.last_round,
                "times": {p: list(v) for p, v in self.times.items()},
                "trials": {p: [dict(trial) for trial in trials] for p, trials in self.trials.items()},
                "best": {p: min(v, default=None) for p, v in values.items()},
                "average": {p: round(sum(v) / len(v)) if v else None for p, v in values.items()},
                "completed": sum(len(v) for v in self.times.values()), "total": self.rounds * len(self.players),
                "phone_latency": "Phone taps include display, input and network delay. Watch the wall and knock for direct wall timing."}

    def voice_words(self):
        return ["go", "start", "ready"]

    def frame_at(self, size, t):
        self.tick()
        c = blank(size)
        phase = self.phase
        back = COLOURS["red"] if phase == "red" else COLOURS["green"] if phase == "green" else COLOURS["ground"]
        ink = COLOURS["red_ink"] if phase == "red" else COLOURS["green_ink"] if phase == "green" else COLOURS["ready"]
        c[:] = back
        unit = size / 64
        # A stop bar, open circle and expanding target distinguish each state
        # without relying on red and green alone. No pulsing or flashing.
        if phase in ("ready", "red", "green"):
            ring(c, size * 0.5, size * 0.30, size * 0.125, max(1, size / 96), ink)
            if phase == "red":
                for x in (27, 34):
                    fill(c, round(x * unit), round(15 * unit), max(1, round(3 * unit)), round(8 * unit), ink)
            elif phase == "green":
                disc(c, size * 0.5, size * 0.30, size * 0.065, ink)
                for x, y, w, h in ((18, 19, 4, 1), (42, 19, 4, 1), (32, 5, 1, 4), (32, 29, 1, 4)):
                    fill(c, round(x * unit), round(y * unit), max(1, round(w * unit)), max(1, round(h * unit)), ink)
            label = "WAIT" if phase == "red" else "NOW" if phase == "green" else "READY"
            scale = max(1, int(size * 0.72 / max(1, text_width(label, 1))))
            text_centred(c, label, size // 2, round(size * 0.52), COLOURS["white"], scale)
        else:
            if self.last_ms is None:
                label = "MISSED" if self.last_kind == "missed" else "EARLY"
                scale = max(1, int(size * 0.78 / text_width(label, 1)))
                text_centred(c, label, size // 2, round(size * 0.39), COLOURS["white"], scale)
                text_centred(c, "NO SCORE", size // 2, round(size * 0.64), COLOURS["error"], max(1, size // 192))
            else:
                label = str(self.last_ms)
                scale = max(1, int(size * 0.82 / text_width(label, 1)))
                scale = min(scale, max(1, int(size * 0.30 / 7)))
                text_centred(c, label, size // 2, round(size * 0.33), COLOURS["white"], scale)
                text_centred(c, "MS", size // 2, round(size * 0.65), COLOURS["dim"], max(1, size // 128))
            if self.over:
                rect(c, round(3 * unit), round(3 * unit), size - round(6 * unit), size - round(6 * unit), COLOURS["ready"], max(1, round(unit)))
        # Trial marks are stable and legible, including all 20 rounds.
        who = self.last_player if phase == "shown" and self.last_player else self.players[self.turn]
        trials = self.trials[who]
        spacing = min(size * 0.075, size * 0.82 / self.rounds)
        radius = max(1, min(size * 0.018, spacing * 0.28))
        start = size * 0.5 - (self.rounds - 1) * spacing / 2
        for i in range(self.rounds):
            x, y = start + i * spacing, size * 0.86
            colour = COLOURS["ready"] if i < len(trials) and trials[i]["ms"] is not None else COLOURS["error"] if i < len(trials) else COLOURS["line"]
            if i < len(trials):
                fill(c, round(x - radius), round(y - radius), max(1, round(radius * 2)), max(1, round(radius * 2)), colour)
            else:
                ring(c, x, y, radius, max(1, radius * 0.5), colour)
        return c
