"""A small night flight, steered by room pitch or an accessible phone target.

The world remains still until a player starts. Its geometry is normalized so
phone and 64/192/512 RGB renderers share bird, pipe and ground positions.
"""
from __future__ import annotations

import math
import random
import time

from . import Game, register
from .board import blank, disc, fill, rounded, text_centred

PITCH_HOLD_S = 0.35
SINK_PER_S = 0.22
GAP = 0.34
PIPE_EVERY = 0.62
GROUND = 60 / 64
BIRD_X = 16 / 64
BIRD_LEFT, BIRD_RIGHT, BIRD_RADIUS = 2 / 64, 4 / 64, 2 / 64
PIPE_WIDTH, PIPE_CAP = 5 / 64, 1 / 64
MAX_FRAME_DELAY = 2.0
PHYSICS_STEP = 1 / 120
COLOURS = {"sky": (13, 23, 37), "horizon": (22, 40, 49), "star": (76, 93, 111),
           "moon": (43, 61, 77), "pipe": (71, 140, 132), "pipe_light": (141, 192, 169),
           "pipe_shade": (41, 89, 92), "bird": (241, 191, 87), "wing": (188, 129, 57),
           "beak": (233, 140, 74), "white": (255, 255, 255), "eye": (17, 28, 35),
           "ground": (59, 80, 66), "ground_edge": (151, 175, 137)}
STARS = [(4, 10), (12, 6), (22, 15), (37, 5), (55, 13), (61, 25), (30, 26),
         (7, 32), (42, 21), (18, 44), (51, 39), (33, 47), (58, 50), (3, 52)]


def finite_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


@register
class WhistleBird(Game):
    name = "whistlebird"
    title = "Whistle bird"
    blurb = "A little night flight. Whistle or slide through the openings."
    min_players = max_players = 1
    by_voice = False

    def setup(self):
        speed = self.options.get("speed", 14.0)
        if not finite_number(speed) or not 4 <= speed <= 40:
            raise ValueError("Choose a flight speed from 4 to 40.")
        self.rng = random.Random(self.options.get("seed"))
        self.speed = float(speed)
        self._clock = getattr(self, "_clock", time.monotonic)
        now = self._now()
        if now is None:
            raise ValueError("The wall’s flight clock is unavailable.")
        self.y = 0.5
        self.target = None
        self.last_pitch_t = -10.0
        self.lo = self.hi = self.calib_until = None
        self.pipes = []
        self._next_pipe_id = 0
        self.score = 0
        self.best = getattr(self, "best", 0)
        self.dead = False
        self.over = self.won = False
        self.finished = self.winner = None
        self.started = time.time()
        self.phase = "ready"
        self.source = "none"
        self.reason = ""
        self.t0 = self.last_t = now
        self.distance = 0.0
        self.elapsed = 0.0
        self.message = "Whistle to begin, or start with touch. Your bird will wait."

    def _now(self):
        value = self._clock()
        return float(value) if finite_number(value) and value >= 0 else None

    def _start(self, source):
        now = self._now()
        if now is None:
            return False
        self.phase, self.source = "flying", source
        self.last_t = now
        self.target = self.y
        self.last_pitch_t = now
        self.message = "Find the opening. A little higher, a little lower."
        self.changed()
        return True

    def event(self, kind, info):
        if self.over:
            return False
        if kind == "pitch":
            if not isinstance(info, dict):
                return False
            return self.pitch(info.get("hz"), info.get("t"))
        return kind in ("double", "whistle", "knock")

    def pitch(self, hz, sample_time=None):
        now = self._now()
        if self.dead or self.over or not finite_number(hz) or not 300 <= hz <= 5000 or now is None:
            return False
        stamp = now if sample_time is None else sample_time
        if not finite_number(stamp) or stamp < 0 or stamp > now + 0.05 or now - stamp > 0.5 or stamp < self.last_pitch_t and self.source == "whistle":
            return False
        # Integrate the previous command up to receipt before changing target;
        # a late pitch must not steer retroactively through an obstacle.
        self.step()
        if self.dead or self.over:
            return False
        if self.phase == "paused":
            self._start("whistle")
        if self.lo is None:
            self.lo = self.hi = float(hz)
            self.calib_until = now + 2.0
        else:
            self.lo = min(self.lo, float(hz))
            self.hi = max(self.hi, float(hz))
        if self.phase == "ready":
            self.phase = "calibrating"
            self.last_t = now
            self.message = "Try a low whistle, then a high one. The bird is safe while it learns."
            self.changed()
        self.source = "whistle"
        self.target = 0.5 if self.hi - self.lo < 60 else 1 - max(0.0, min(1.0, (hz - self.lo) / (self.hi - self.lo)))
        self.last_pitch_t = float(stamp)
        return True

    def apply(self, move, player):
        if not isinstance(move, dict) or len(move) != 1:
            return {"error": "Choose a flight height or start the flight."}
        if set(move) == {"again"} and move["again"] is True:
            # Legacy clients can still restart explicitly; reset every base
            # completion flag too. The native app uses the shared new-game flow.
            self.setup()
            self.changed()
            return {"again": True}
        if self.dead or self.over:
            return {"error": "This flight is finished. Start a new flight from the results."}
        if set(move) == {"start"} and move["start"] is True:
            if self.phase not in ("ready", "paused", "calibrating"):
                return {"error": "The bird is already flying."}
            return {"started": True} if self._start("phone") else {"error": "The flight clock is unavailable."}
        if set(move) == {"y"}:
            y = move["y"]
            if not finite_number(y) or not 0 <= y <= 1:
                return {"error": "Flight height must be a number from 0 to 1."}
            if self._now() is None:
                return {"error": "The flight clock is unavailable."}
            self.step()
            if self.dead:
                return {"error": "This flight has finished."}
            if self.phase in ("ready", "calibrating", "paused"):
                self._start("phone")
            self.source, self.target = "phone", float(y)
            self.last_pitch_t = self._now()
            self.changed()
            return {"y": self.target}
        return {"error": "Choose a flight height or start the flight."}

    def hear(self, spoken, player):
        if isinstance(spoken, str) and spoken.lower().strip(" .!") in ("again", "restart", "play again"):
            return self.apply({"again": True}, player)
        return None

    def _collision(self):
        if self.y + BIRD_RADIUS >= GROUND:
            return "ground"
        left, right = BIRD_X - BIRD_LEFT, BIRD_X + BIRD_RIGHT
        for pipe in self.pipes:
            if pipe[0] - PIPE_CAP < right and pipe[0] + PIPE_WIDTH + PIPE_CAP > left:
                if self.y - BIRD_RADIUS < pipe[1] - GAP / 2 or self.y + BIRD_RADIUS > pipe[1] + GAP / 2:
                    return "pipe"
        return None

    def step(self):
        now = self._now()
        if now is None or now < self.last_t:
            return
        dt = now - self.last_t
        self.last_t = now
        if self.dead or self.over or self.phase in ("ready", "paused"):
            return
        if self.phase == "calibrating":
            if self.calib_until is not None and now >= self.calib_until:
                self.phase = "flying"
                self.message = "Your range is set. Whistle high to rise and low to descend."
                self.changed()
            return
        if dt > MAX_FRAME_DELAY:
            self.phase = "paused"
            self.message = "Flight paused. Your place is saved; continue when you're ready."
            self.changed()
            return
        # Validate the current pose even with dt=0: collisions do not depend on
        # whether the call came from a display frame or a status request.
        collision = self._collision()
        if collision:
            self._die(collision)
            return
        count = max(1, math.ceil(dt / PHYSICS_STEP))
        step = dt / count
        for index in range(count):
            clock = now - dt + (index + 1) * step
            if self.target is not None and (self.source == "phone" or clock - self.last_pitch_t <= PITCH_HOLD_S):
                self.y += (self.target - self.y) * (1 - math.exp(-6 * step))
            else:
                self.y += SINK_PER_S * step
            self.y = max(BIRD_RADIUS, self.y)
            movement = self.speed * step / 64
            self.distance += movement
            self.elapsed += step
            for pipe in self.pipes:
                pipe[0] -= movement
                while len(pipe) < 4:
                    pipe.append(False if len(pipe) == 2 else self._next_pipe_id)
                    if len(pipe) == 4:
                        self._next_pipe_id += 1
            collision = self._collision()
            if collision:
                self._die(collision)
                return
            for pipe in self.pipes:
                if not pipe[2] and pipe[0] + PIPE_WIDTH + PIPE_CAP < BIRD_X - BIRD_LEFT:
                    pipe[2] = True
                    self.score += 1
                    self.best = max(self.best, self.score)
                    self.message = f"{self.score} {'opening' if self.score == 1 else 'openings'} cleared."
                    self.changed()
            self.pipes = [pipe for pipe in self.pipes if pipe[0] + PIPE_WIDTH + PIPE_CAP > 0]
            if not self.pipes or self.pipes[-1][0] < 1 - PIPE_EVERY:
                if self.distance > 0.5 or self.pipes:
                    self.pipes.append([1.05, self.rng.uniform(0.26, 0.68), False, self._next_pipe_id])
                    self._next_pipe_id += 1

    def _die(self, reason="pipe"):
        if self.dead or self.over:
            return
        self.dead, self.phase, self.reason = True, "finished", reason
        self.finish(won=self.score > 0, message=f"{self.score} {'opening' if self.score == 1 else 'openings'} cleared. A little further next time.")

    def state(self):
        self.step()
        now = self._now() or self.last_t
        calibration = max(0.0, min(1.0, 1 - ((self.calib_until or now) - now) / 2)) if self.phase == "calibrating" else 1.0
        return {"phase": self.phase, "y": round(self.y, 5), "target": self.target, "source": self.source,
                "score": self.score, "best": self.best, "dead": self.dead, "reason": self.reason,
                "pipes": [[round(p[0], 5), round(p[1], 5)] for p in self.pipes],
                "obstacles": [{"id": p[3] if len(p) > 3 else i, "x": round(p[0], 5), "gap": p[1], "passed": bool(p[2]) if len(p) > 2 else False} for i, p in enumerate(self.pipes)],
                "range": [self.lo, self.hi] if self.lo is not None else None,
                "calibration": round(calibration, 3), "sample_time": now, "elapsed": round(self.elapsed, 5),
                "distance": round(self.distance, 5), "speed": self.speed / 64, "gap_size": GAP, "ground": GROUND}

    def frame_at(self, size, t):
        self.step()
        c = blank(size)
        c[:] = COLOURS["sky"]
        unit = size / 64
        fill(c, 0, round(size * 0.78), size, size, COLOURS["horizon"])
        disc(c, size * 0.80, size * 0.18, size * 0.055, COLOURS["moon"])
        for sx, sy in STARS:
            x = (sx / 64 - self.distance * 0.08) % 1
            fill(c, round(x * size), round(sy * unit), max(1, round(unit * 0.45)), max(1, round(unit * 0.45)), COLOURS["star"])
        ground_y = round(GROUND * size)
        fill(c, 0, ground_y, size, size - ground_y, COLOURS["ground"])
        fill(c, 0, ground_y, size, max(1, round(unit)), COLOURS["ground_edge"])
        for pipe in self.pipes:
            x = round(pipe[0] * size)
            width = round(PIPE_WIDTH * size)
            top, bottom = round((pipe[1] - GAP / 2) * size), round((pipe[1] + GAP / 2) * size)
            for y, height in ((0, top), (bottom, ground_y - bottom)):
                fill(c, x, y, width, height, COLOURS["pipe"])
                fill(c, x, y, max(1, round(unit)), height, COLOURS["pipe_light"])
                fill(c, x + width - max(1, round(unit)), y, max(1, round(unit)), height, COLOURS["pipe_shade"])
            fill(c, x - round(unit), top - round(unit * 2), width + round(unit * 2), round(unit * 2), COLOURS["pipe_light"])
            fill(c, x - round(unit), bottom, width + round(unit * 2), round(unit * 2), COLOURS["pipe_light"])
        bx, by = round(BIRD_X * size), round(self.y * size)
        flap = int(self.elapsed * 6) % 2 == 0 and self.phase == "flying"
        rounded(c, bx - round(unit * 2), by - round(unit * 2), round(unit * 5), round(unit * 4), COLOURS["bird"], max(1, round(unit)))
        fill(c, bx - round(unit * 2), by + (0 if flap else round(unit)), round(unit * 2), round(unit), COLOURS["wing"])
        fill(c, bx + round(unit * 3), by, max(1, round(unit)), max(1, round(unit)), COLOURS["beak"])
        fill(c, bx + round(unit), by - round(unit), max(1, round(unit)), max(1, round(unit)), COLOURS["eye"])
        label = "READY" if self.phase == "ready" else "RANGE" if self.phase == "calibrating" else "PAUSED" if self.phase == "paused" else str(self.score)
        scale = max(1, int(size / (96 if label.isdigit() else 192)))
        text_centred(c, label, size // 2, round(size * 0.065), COLOURS["white"], scale)
        if self.dead:
            text_centred(c, "LANDED", size // 2, round(size * 0.68), COLOURS["white"], max(1, size // 192))
        return c
