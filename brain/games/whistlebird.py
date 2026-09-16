"""Whistle bird.

A bird flies through gaps in pipes, and the pitch of your whistle is its
height: whistle high to climb, low to dive, stop and it sinks. The first
two seconds of whistling set your range, so a low whistler and a high one
both reach the top. The pitch comes from the ear (brain/nowplaying/knock.py
hands every tonal window to the running game, ten or more a second). The
phone can steer instead, with a finger up and down the screen.

The wall draws it at 64 and at 192: the bird a few pixels, the pipes
columns with a gap, the score in the corner; a pipe passed is a point. It
runs at the game host's frame rate, thirty a second at most. Options:
{"speed": pixels per second at 64, default 14}.
"""
from __future__ import annotations

import random
import time

from . import Game, register
from .board import (BLACK, DIM, GREEN, INK, ORANGE, WHITE, YELLOW, banner, blank, ease_out, fill, mix, rounded, scale_for, text_centred)

PITCH_HOLD_S = 0.35         # how long the last whistle steers after it stops
SINK_PER_S = 0.22           # of the height, per second, when silent
GAP = 0.34                  # of the height
PIPE_EVERY = 0.62           # of the width, between pipes


@register
class WhistleBird(Game):
    name = "whistlebird"
    title = "Whistle bird"
    blurb = "Whistle high to climb, low to dive, through the gaps."
    min_players = 1
    max_players = 1
    by_voice = False

    def setup(self):
        self.rng = random.Random(self.options.get("seed"))
        self.speed = float(self.options.get("speed", 14.0))      # px/s at 64
        self.y = 0.5                    # 0 top .. 1 bottom
        self.target: float | None = None
        self.last_pitch_t = -10.0
        self.lo: float | None = None    # the whistler's range, learnt
        self.hi: float | None = None
        self.calib_until: float | None = None
        self.pipes: list[list[float]] = []      # [x (0..1 across), gap centre (0..1)]
        self.score = 0
        self.best = 0
        self.dead = False
        self.t0 = time.monotonic()
        self.last_t = self.t0
        self.distance = 0.0
        self.message = "Whistle to fly."
        self._clock = time.monotonic

    # ---- steering --------------------------------------------------------------------------------
    def event(self, kind: str, info: dict) -> bool:
        if kind == "pitch":
            self.pitch(float(info.get("hz", 0.0)))
            return True
        return kind in ("double", "whistle", "knock")

    def pitch(self, hz: float):
        if hz <= 0 or self.dead:
            return
        now = self._clock()
        if self.lo is None:
            self.lo = self.hi = hz
            self.calib_until = now + 2.0
        self.lo = min(self.lo, hz)
        self.hi = max(self.hi, hz)
        # the range keeps learning, slowly, so a new high note extends it
        if self.hi - self.lo < 60.0:
            self.target = 0.5
        else:
            f = (hz - self.lo) / (self.hi - self.lo)
            self.target = 1.0 - max(0.0, min(1.0, f))         # high pitch = high on the panel
        self.last_pitch_t = now

    def apply(self, move: dict, player: str) -> dict:
        if move.get("again") or move.get("start"):
            self.setup()
            self.changed()
            return {"again": True}
        if "y" in move:
            try:
                self.target = max(0.0, min(1.0, float(move["y"])))
            except (TypeError, ValueError):
                return {"error": "y from 0 to 1"}
            self.last_pitch_t = self._clock()
            return {"y": self.target}
        return {"error": "y, or again"}

    def hear(self, text: str, player: str) -> dict | None:
        if text.lower().strip(" .!") in ("again", "restart", "play again"):
            return self.apply({"again": True}, player)
        return None

    # ---- the world ----------------------------------------------------------------------------
    def step(self):
        now = self._clock()
        dt = min(0.1, max(0.0, now - self.last_t))
        self.last_t = now
        if self.dead:
            return
        if self.target is not None and now - self.last_pitch_t <= PITCH_HOLD_S:
            self.y += (self.target - self.y) * min(1.0, 6.0 * dt)
        else:
            self.y = min(1.0, self.y + SINK_PER_S * dt)
        move = self.speed * dt / 64.0                            # in widths per second at 64
        self.distance += move
        for p in self.pipes:
            p[0] -= move
        self.pipes = [p for p in self.pipes if p[0] > -0.1]
        if not self.pipes or self.pipes[-1][0] < 1.0 - PIPE_EVERY:
            if self.distance > 0.8 or self.pipes:
                self.pipes.append([1.05, self.rng.uniform(0.25, 0.75)])
        bird_x = 0.25
        for p in self.pipes:
            if len(p) == 2:
                p.append(False)                                  # passed?
            if not p[2] and p[0] < bird_x - 0.04:
                p[2] = True
                self.score += 1
                self.best = max(self.best, self.score)
                self.message = f"{self.score}."
                self.changed()
            if abs(p[0] - bird_x) < 0.05 and abs(self.y - p[1]) > GAP / 2:
                self._die()
        if self.y >= 0.995:
            self._die()

    def _die(self):
        self.dead = True
        self.message = f"{self.score}. Say again."
        self.finish(won=self.score > 0, message=self.message)

    def state(self) -> dict:
        self.step()
        return {"y": round(self.y, 3), "score": self.score, "dead": self.dead,
                "pipes": [[round(p[0], 3), round(p[1], 3)] for p in self.pipes],
                "range": [self.lo, self.hi] if self.lo is not None else None}

    def frame_at(self, size: int, t: float):
        self.step()
        s = scale_for(size)
        c = blank(size)
        # a night sky, a few faint stars that scroll slowly, the ground
        c[...] = (6, 8, 18)
        rng = random.Random(3)
        for _ in range(14 if s == 1 else 40):
            sx, sy = rng.randrange(size), rng.randrange(size - 6 * s)
            sx = (sx - int(self.distance * size * 0.15)) % size
            c[sy, sx] = (26, 28, 44)
        fill(c, 0, size - 2 * s, size, 2 * s, (48, 78, 40))
        fill(c, 0, size - 2 * s, size, 1, (70, 110, 56))
        gap_px = int(GAP * size)
        pipe_w = 5 * s
        for p in self.pipes:
            x = int(p[0] * size)
            gy = int(p[1] * size)
            top_h = max(0, gy - gap_px // 2)
            bot_y = gy + gap_px // 2
            for (py, ph) in ((0, top_h), (bot_y, size - bot_y - 2 * s)):
                if ph <= 0:
                    continue
                fill(c, x, py, pipe_w, ph, GREEN)
                fill(c, x, py, 1 if s == 1 else 2, ph, mix(GREEN, WHITE, 0.25))
                fill(c, x + pipe_w - (1 if s == 1 else 2), py, 1 if s == 1 else 2, ph, mix(GREEN, BLACK, 0.4))
            rounded(c, x - s, top_h - 2 * s, pipe_w + 2 * s, 2 * s, mix(GREEN, WHITE, 0.1), 1)
            rounded(c, x - s, bot_y, pipe_w + 2 * s, 2 * s, mix(GREEN, WHITE, 0.1), 1)
        bx, by = int(0.25 * size), int(self.y * (size - 2 * s))
        flap = int(t * 8) % 2 == 0 and not self.dead
        rounded(c, bx - 2 * s, by - s, 5 * s, 3 * s, YELLOW, 1)
        fill(c, bx - 2 * s, by + (0 if flap else s), 2 * s, s, mix(YELLOW, BLACK, 0.3))     # the wing
        fill(c, bx + 3 * s, by, s, s, ORANGE)                                                  # the beak
        fill(c, bx + s, by - s, s, s, WHITE)
        fill(c, bx + s, by - s, 1 if s == 1 else 2, 1 if s == 1 else 2, BLACK)                   # the eye
        pop = 1.0 + 0.5 * (1.0 - ease_out(self.age() / 0.3)) if self.age() < 0.3 and self.score else 1.0
        text_centred(c, str(self.score), size // 2, 2 * s, INK, max(1, int(round(s * pop))))
        if self.dead:
            banner(c, size, f"{self.score}. again?", INK, (40, 30, 30))
        elif self.lo is None:
            text_centred(c, "whistle", size // 2, size - 10 * s, DIM, s)
        return c

