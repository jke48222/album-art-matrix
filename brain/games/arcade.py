"""The arcade: Pong, Snake and Tetris on the wall.

Pong: two paddles, a ball, first to seven. Each player's phone is a
paddle: tilt it, or slide a finger, and it posts where the paddle should
be ({"paddle": 0..1}) many times a second. One player plays the wall,
which returns the ball with a little error. The court is the panel.

Snake: the wall runs it; the phone is the remote ({"dir": "up" | "down"
| "left" | "right"}, or the same words said). A 32-cell grid, so every
segment is two LEDs at 64 and six at 192; food; the score; walls kill.

Tetris: a ten-by-twenty well, three LEDs a cell at 64 and nine at 192;
the seven pieces from a shuffled bag, rotation with kicks off the walls,
lines, levels that speed up, a ghost where the piece will land; the
phone's remote ({"move": "left" | "right" | "rotate" | "down" | "drop"}).

All three step on the wall's own clock when drawn, at the host's rate,
up to thirty frames a second.
"""
from __future__ import annotations

import random
import time

from . import Game, register
from .board import (BLACK, BLUE, DIM, EDGE, FAINT, GREEN, INK, ORANGE, PURPLE, RED, WHITE, YELLOW,
                    banner, blank, disc, fill, glow, mix, outline, rounded, scale_for, text, text_right, tile)

DIRS = {"up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}


@register
class Pong(Game):
    name = "pong"
    title = "Pong"
    blurb = "A quiet court. Slide your paddle, or choose calibrated tilt. First to seven."
    min_players = 1
    max_players = 2
    by_voice = False

    STEP = 1 / 120
    MAX_DELAY = 1.0
    BALL_R = 1.15 / 64
    COURT_TOP, COURT_BOTTOM = 0.22, 0.94
    PAD_X, PAD_W = 0.055, 0.018
    COLOURS = {"ground": (12, 23, 28), "court": (16, 33, 39), "line": (58, 80, 81),
               "left": (149, 207, 181), "right": (133, 183, 222), "ball": (247, 201, 100),
               "white": (255, 255, 255), "dim": (163, 177, 172), "trail": (102, 90, 59)}

    @staticmethod
    def _finite(value):
        import math
        if type(value) not in (int, float):
            return False
        try:
            return math.isfinite(value)
        except OverflowError:
            return False

    def _now(self):
        value = self._clock()
        return float(value) if self._finite(value) and value >= 0 else None

    def setup(self):
        target = self.options.get("to", 7)
        if type(target) is not int or not 1 <= target <= 21:
            raise ValueError("Choose a winning score from 1 to 21.")
        self.to = target
        self.rng = random.Random(self.options.get("seed"))
        self._clock = getattr(self, "_clock", time.monotonic)
        now = self._now()
        if now is None:
            raise ValueError("The court clock is unavailable.")
        self.pad_h = 0.22
        self.paddles = [0.5, 0.5]
        self.score = [0, 0]
        self.ball, self.vel = [0.5, 0.5], [0.0, 0.0]
        self.trail = []
        self.last_t = now
        self.accumulator = 0.0
        self.wait_until = now
        self.phase = "ready"
        self.paused_phase = "ready"
        self.paused_remaining = 0.0
        self.next_direction = self.rng.choice((-1, 1))
        self.ai_error = self.rng.uniform(-0.065, 0.065)
        self.rally = self.longest_rally = self.point_number = 0
        self.last_point = None
        self.over = self.won = False
        self.winner = self.finished = None
        self.started = time.time()
        self.message = "Find your position. Serve when you’re ready."

    def serve(self, direction=1):
        import math
        if self.over or direction not in (-1, 1):
            return False
        now = self._now()
        if now is None:
            return False
        self.ball = [0.5, 0.5]
        angle = self.rng.uniform(-0.55, 0.55)
        self.vel = [direction * .45 * math.cos(angle), .45 * math.sin(angle)]
        self.next_direction = direction
        self.trail = []
        self.rally = 0
        self.phase = "serve"
        self.wait_until = now + 1.0
        self.last_t = now
        self.accumulator = 0.0
        self.ai_error = self.rng.uniform(-0.065, 0.065)
        self.message = "Serve coming. Keep your paddle ready."
        self.changed()
        return True

    def apply(self, move, player):
        if not isinstance(move, dict) or not move:
            return {"error": "Choose a paddle position, serve, pause or resume."}
        if set(move) == {"again"} and move["again"] is True:
            self.setup()
            self.changed()
            return {"again": True}
        if self.over:
            return {"error": "This match is finished. Start another from the results."}
        if set(move) in ({"paddle"}, {"paddle", "side"}):
            value = move["paddle"]
            if not self._finite(value) or not 0 <= value <= 1:
                return {"error": "Paddle position must be a number from 0 to 1."}
            if player not in self.players:
                return {"error": "Choose a player in this match."}
            side = self.players.index(player)
            if "side" in move and (type(move["side"]) is not int or move["side"] != side):
                return {"error": "Move the paddle for your selected player."}
            if self._now() is None:
                return {"error": "The court clock is unavailable."}
            self.step()  # New input never changes the preceding physics interval.
            if self.over:
                return {"error": "This match just finished."}
            y = min(1 - self.pad_h / 2, max(self.pad_h / 2, float(value)))
            self.paddles[side] = y
            self.changed()
            return {"paddle": y, "side": side}
        if set(move) == {"serve"} and move["serve"] is True:
            if self.phase != "ready":
                return {"error": "A serve is already in progress."}
            return {"served": True} if self.serve(self.next_direction) else {"error": "The court clock is unavailable."}
        if set(move) == {"pause"} and move["pause"] is True:
            self.step()
            if self.over:
                return {"error": "This match is finished."}
            if self.phase not in ("serve", "rally", "point"):
                return {"error": "The court is already at rest."}
            self._pause("Match paused. Your court is saved.")
            return {"paused": True}
        if set(move) == {"resume"} and move["resume"] is True:
            now = self._now()
            if self.phase != "paused" or now is None:
                return {"error": "There is no paused rally to resume."}
            self.phase = self.paused_phase
            self.wait_until = now + self.paused_remaining
            self.last_t, self.accumulator = now, 0.0
            self.message = "Back on court."
            self.changed()
            return {"resumed": True}
        return {"error": "Choose one paddle, serve, pause or resume command."}

    def _pause(self, message):
        now = self._now()
        self.paused_phase = self.phase
        self.paused_remaining = max(0.0, self.wait_until - (now if now is not None else self.last_t))
        self.phase, self.accumulator = "paused", 0.0
        self.message = message
        self.changed()

    def _point(self, scorer):
        self.score[scorer] += 1
        self.last_point = scorer
        self.point_number += 1
        self.trail = []
        self.vel = [0.0, 0.0]
        self.next_direction = -1 if scorer == 0 else 1
        if self.score[scorer] >= self.to:
            self.phase = "finished"
            winner = self.players[scorer] if len(self.players) == 2 else None
            who = self.players[scorer] if scorer < len(self.players) else "The wall"
            self.finish(won=scorer == 0 if len(self.players) == 1 else True, winner=winner,
                        message=f"Match to {who}. {max(self.score)}–{min(self.score)}.")
        else:
            self.phase = "point"
            self.wait_until = (self._now() or self.last_t) + 1.2
            who = self.players[scorer] if scorer < len(self.players) else "The wall"
            self.message = f"Point to {who}. {self.score[0]}–{self.score[1]}."
            self.changed()

    def _advance(self, duration):
        import math
        half = self.pad_h / 2
        if len(self.players) == 1:
            target = min(1 - half, max(half, self.ball[1] + self.ai_error))
            delta = target - self.paddles[1]
            self.paddles[1] += max(-.65 * duration, min(.65 * duration, delta))
        radius_y = self.BALL_R / (self.COURT_BOTTOM - self.COURT_TOP)
        left = self.PAD_X + self.PAD_W / 2 + self.BALL_R
        right = 1 - left
        remaining = duration
        for _ in range(5):
            if remaining <= 1e-10 or self.phase != "rally":
                break
            x, y = self.ball
            vx, vy = self.vel
            events = []
            if vy < 0:
                events.append((max(0., (radius_y - y) / vy), "top"))
            elif vy > 0:
                events.append((max(0., (1 - radius_y - y) / vy), "bottom"))
            if vx < 0:
                events.append((max(0., (left - x) / vx), "left"))
            elif vx > 0:
                events.append((max(0., (right - x) / vx), "right"))
            travel, event = min(events, default=(remaining + 1, ""))
            if travel > remaining:
                self.ball = [x + vx * remaining, y + vy * remaining]
                break
            self.ball = [x + vx * travel, y + vy * travel]
            remaining -= travel
            if event in ("top", "bottom"):
                self.ball[1] = radius_y if event == "top" else 1 - radius_y
                self.vel[1] = -vy
            else:
                side = 0 if event == "left" else 1
                self.ball[0] = left if side == 0 else right
                offset = self.ball[1] - self.paddles[side]
                if abs(offset) > half + radius_y:
                    self._point(1 - side)
                    break
                speed = min(1.2, max(.45, math.hypot(vx, vy) * 1.04))
                angle = max(-1, min(1, offset / half)) * .95
                self.vel = [(1 if side == 0 else -1) * speed * math.cos(angle), speed * math.sin(angle)]
                self.rally += 1
                self.longest_rally = max(self.longest_rally, self.rally)
        self.trail.append(list(self.ball))
        del self.trail[:-9]

    def step(self):
        now = self._now()
        if now is None or now < self.last_t:
            return
        previous, self.last_t = self.last_t, now
        dt = now - previous
        if self.over or self.phase in ("ready", "paused"):
            return
        ctrl = getattr(self.host, "ctrl", None)
        if ctrl is not None and getattr(self.host, "game", None) is self and ctrl.get().get("mode") != "game":
            self._pause("Your match is saved while the wall shows something else. Return to the court to resume.")
            return
        if dt > self.MAX_DELAY:
            # Preserve countdown time from before a delayed frame, too.
            remaining = max(0.0, self.wait_until - previous)
            self._pause("The court paused while the wall caught up. Resume when you’re ready.")
            self.paused_remaining = remaining
            return
        if self.phase == "point":
            if now >= self.wait_until:
                self.serve(self.next_direction)
            return
        if self.phase == "serve":
            if now < self.wait_until:
                return
            self.phase = "rally"
            self.message = "Keep the rally alive."
            dt = max(0.0, now - max(previous, self.wait_until))
            self.changed()
        self.accumulator += dt
        while self.accumulator + 1e-10 >= self.STEP and self.phase == "rally":
            self.accumulator = max(0.0, self.accumulator - self.STEP)
            self._advance(self.STEP)
        if self.phase != "rally":
            self.accumulator = 0.0

    def state(self):
        self.step()
        now = self._now()
        return {"ball": [round(v, 5) for v in self.ball], "velocity": list(self.vel),
                "paddles": [round(p, 5) for p in self.paddles], "score": list(self.score), "to": self.to,
                "phase": self.phase, "rally": self.rally, "longest_rally": self.longest_rally,
                "point_number": self.point_number, "last_point": self.last_point,
                "serve_remaining": round(max(0., self.wait_until - (now if now is not None else self.last_t)), 3) if self.phase == "serve" else 0,
                "sample_time": now if now is not None else self.last_t,
                "trail": [list(p) for p in self.trail], "paddle_height": self.pad_h,
                "court_top": self.COURT_TOP, "court_bottom": self.COURT_BOTTOM,
                "ball_radius": self.BALL_R, "paddle_x": self.PAD_X, "paddle_width": self.PAD_W,
                "opponent": self.players[1] if len(self.players) == 2 else "The wall"}

    def frame_at(self, size, t):
        from .board import rect, text_centred
        self.step()
        c = blank(size)
        colours = self.COLOURS
        c[:] = colours["ground"]
        top, bottom = self.COURT_TOP * size, self.COURT_BOTTOM * size
        court_h = bottom - top
        margin = round(size * .025)
        fill(c, margin, round(top), size - margin * 2, round(court_h), colours["court"])
        rect(c, margin, round(top), size - margin * 2, round(court_h), colours["line"], max(1, round(size / 256)))
        for index in range(10):
            fill(c, round(size * .5), round(top + court_h * (index / 10 + .02)), max(1, round(size / 256)), max(1, round(court_h * .045)), colours["line"])
        scale = max(1, int(size * .12 / 7))
        text_centred(c, str(self.score[0]), round(size * .28), round(size * .035), colours["left"], scale)
        text_centred(c, str(self.score[1]), round(size * .72), round(size * .035), colours["right"], scale)
        for side in (0, 1):
            px = self.PAD_X if side == 0 else 1 - self.PAD_X
            colour = colours["left"] if side == 0 else colours["right"]
            rounded(c, round((px - self.PAD_W / 2) * size), round(top + (self.paddles[side] - self.pad_h / 2) * court_h),
                    max(1, round(self.PAD_W * size)), max(1, round(self.pad_h * court_h)), colour, max(1, round(size / 256)))
        for index, (x, y) in enumerate(self.trail[:-1]):
            opacity = (index + 1) / max(1, len(self.trail)) * .65
            disc(c, x * size, top + y * court_h, max(1, self.BALL_R * size * .6), mix(colours["court"], colours["trail"], opacity))
        disc(c, self.ball[0] * size, top + self.ball[1] * court_h, max(1, self.BALL_R * size), colours["ball"])
        if self.phase in ("ready", "serve", "paused", "finished"):
            label = {"ready": "READY", "serve": "SERVE", "paused": "PAUSED", "finished": "FINAL"}[self.phase]
            text_centred(c, label, size // 2, round(size * .14), colours["white"], max(1, size // 192))
        return c

@register
class Snake(Game):
    name = "snake"
    title = "Snake"
    blurb = "The phone is the remote. Eat, grow, do not hit the wall."
    min_players = 1
    max_players = 1

    N = 32

    def setup(self):
        self.rng = random.Random(self.options.get("seed"))
        self.body = [(16, 16), (15, 16), (14, 16)]
        self.dir = (1, 0)
        self.next_dir = (1, 0)
        self.food = self._food()
        self.score = 0
        self.step_s = float(self.options.get("step", 0.16))
        self.last_step = time.monotonic()
        self._clock = time.monotonic
        self.message = "Go."

    def _food(self):
        while True:
            p = (self.rng.randrange(self.N), self.rng.randrange(self.N))
            if p not in self.body:
                return p

    def apply(self, move: dict, player: str) -> dict:
        if move.get("again"):
            self.setup()
            self.over = self.won = False
            self.changed()
            return {"again": True}
        d = DIRS.get(str(move.get("dir") or move.get("direction") or "").lower())
        if d is None:
            return {"error": "up, down, left or right"}
        if (d[0] + self.dir[0], d[1] + self.dir[1]) != (0, 0):      # not straight back
            self.next_dir = d
        return {"dir": d}

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip(" .!")
        if t in DIRS:
            return self.apply({"dir": t}, player)
        if t in ("again", "restart"):
            return self.apply({"again": True}, player)
        return None

    def step(self):
        now = self._clock()
        while not self.over and now - self.last_step >= self.step_s:
            self.last_step += self.step_s
            self.dir = self.next_dir
            hx, hy = self.body[0]
            nx, ny = hx + self.dir[0], hy + self.dir[1]
            if not (0 <= nx < self.N and 0 <= ny < self.N) or (nx, ny) in self.body[:-1]:
                self.finish(won=self.score > 0, message=f"{self.score}. Say again.")
                return
            self.body.insert(0, (nx, ny))
            if (nx, ny) == self.food:
                self.score += 1
                self.food = self._food()
                self.step_s = max(0.07, self.step_s * 0.97)
                self.message = f"{self.score}."
                self.changed()
            else:
                self.body.pop()

    def state(self) -> dict:
        self.step()
        return {"body": [list(p) for p in self.body[:200]], "food": list(self.food), "score": self.score, "n": self.N}

    def voice_words(self) -> list[str]:
        return list(DIRS) + ["again"]

    def frame_at(self, size: int, t: float):
        self.step()
        c = blank(size)
        cell = size // self.N
        if cell >= 3:
            for y in range(self.N):
                for x in range(self.N):
                    if (x + y) % 2 == 0:
                        fill(c, x * cell, y * cell, cell, cell, (9, 9, 12))
        n = len(self.body)
        for i, (x, y) in enumerate(reversed(self.body)):
            f = (i + 1) / n
            col = mix((30, 70, 34), GREEN, f)
            rounded(c, x * cell, y * cell, cell, cell, col, 1 if cell >= 4 else 0)
        hx, hy = self.body[0]
        rounded(c, hx * cell, hy * cell, cell, cell, (140, 230, 100), 1 if cell >= 4 else 0)
        if cell >= 4:
            ex = hx * cell + (cell - 2 if self.dir[0] > 0 else 1 if self.dir[0] < 0 else cell // 2)
            ey = hy * cell + (cell - 2 if self.dir[1] > 0 else 1 if self.dir[1] < 0 else cell // 2)
            fill(c, ex, ey, 1, 1, BLACK)
        fx, fy = self.food
        disc(c, fx * cell + cell / 2, fy * cell + cell / 2, cell / 2, RED)
        fill(c, fx * cell + cell // 2, fy * cell, 1, 1, GREEN)
        text(c, str(self.score), 2, 2, INK, 1 if cell < 4 else 2)
        if self.over:
            banner(c, size, f"{self.score}. again?", INK, (40, 30, 30))
        return c

PIECES = {
    "I": [(0, 1), (1, 1), (2, 1), (3, 1)], "O": [(1, 0), (2, 0), (1, 1), (2, 1)],
    "T": [(1, 0), (0, 1), (1, 1), (2, 1)], "S": [(1, 0), (2, 0), (0, 1), (1, 1)],
    "Z": [(0, 0), (1, 0), (1, 1), (2, 1)], "J": [(0, 0), (0, 1), (1, 1), (2, 1)],
    "L": [(2, 0), (0, 1), (1, 1), (2, 1)],
}
COLOURS = {"I": (80, 200, 220), "O": YELLOW, "T": PURPLE, "S": GREEN, "Z": RED, "J": BLUE, "L": ORANGE}


def rotated(cells, times: int):
    out = list(cells)
    for _ in range(times % 4):
        out = [(3 - y, x) if len({c[0] for c in cells}) == 4 or len({c[1] for c in cells}) == 4 else (2 - y, x)
               for x, y in out]
    return out


@register
class Tetris(Game):
    name = "tetris"
    title = "Tetris"
    blurb = "The phone is the remote: left, right, rotate, drop."
    min_players = 1
    max_players = 1

    W, H = 10, 20

    def setup(self):
        self.rng = random.Random(self.options.get("seed"))
        self.well = [[None] * self.W for _ in range(self.H)]
        self.bag: list[str] = []
        self.score = 0
        self.lines = 0
        self.level = 1
        self._clock = time.monotonic
        self.last_fall = self._clock()
        self.piece = None
        self.cleared = None                  # (rows, when) for the flash
        self._spawn()
        self.message = "Go."

    def _next_kind(self) -> str:
        if not self.bag:
            self.bag = list(PIECES)
            self.rng.shuffle(self.bag)
        return self.bag.pop()

    def _spawn(self):
        kind = self._next_kind()
        self.piece = {"kind": kind, "x": 3, "y": 0, "r": 0}
        if not self._fits(self.piece):
            self.finish(won=self.lines > 0, message=f"{self.score}. Say again.")

    def _cells(self, p):
        return [(p["x"] + x, p["y"] + y) for x, y in rotated(PIECES[p["kind"]], p["r"])]

    def _fits(self, p) -> bool:
        for x, y in self._cells(p):
            if x < 0 or x >= self.W or y >= self.H or (y >= 0 and self.well[y][x] is not None):
                return False
        return True

    def _lock(self):
        for x, y in self._cells(self.piece):
            if 0 <= y < self.H:
                self.well[y][x] = self.piece["kind"]
        full = [y for y in range(self.H) if all(self.well[y])]
        if full:
            import time as _time
            self.cleared = (list(full), _time.monotonic())
        for y in full:
            del self.well[y]
            self.well.insert(0, [None] * self.W)
        if full:
            self.lines += len(full)
            self.score += [0, 100, 300, 500, 800][len(full)] * self.level
            self.level = 1 + self.lines // 10
            self.message = f"{self.score}."
        self._spawn()
        self.changed()

    def fall_s(self) -> float:
        return max(0.08, 0.8 * (0.85 ** (self.level - 1)))

    def step(self):
        now = self._clock()
        while not self.over and now - self.last_fall >= self.fall_s():
            self.last_fall += self.fall_s()
            self._down()

    def _down(self) -> bool:
        p = dict(self.piece, y=self.piece["y"] + 1)
        if self._fits(p):
            self.piece = p
            return True
        self._lock()
        return False

    def apply(self, move: dict, player: str) -> dict:
        if move.get("again"):
            self.setup()
            self.over = self.won = False
            self.changed()
            return {"again": True}
        m = str(move.get("move") or move.get("dir") or "").lower()
        if self.over:
            return {"error": "the game is over"}
        if m in ("left", "right"):
            p = dict(self.piece, x=self.piece["x"] + (1 if m == "right" else -1))
            if self._fits(p):
                self.piece = p
        elif m == "rotate":
            for kick in (0, -1, 1, -2, 2):
                p = dict(self.piece, r=(self.piece["r"] + 1) % 4, x=self.piece["x"] + kick)
                if self._fits(p):
                    self.piece = p
                    break
        elif m == "down":
            if self._down():
                self.score += 1
        elif m == "drop":
            n = 0
            while self._down():
                n += 1
                if self.over:
                    break
            self.score += 2 * n
        else:
            return {"error": "left, right, rotate, down or drop"}
        self.changed()
        return {"move": m, "piece": self.piece}

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip(" .!")
        t = {"turn": "rotate", "spin": "rotate", "fall": "drop", "slam": "drop"}.get(t, t)
        if t in ("left", "right", "rotate", "down", "drop"):
            return self.apply({"move": t}, player)
        if t in ("again", "restart"):
            return self.apply({"again": True}, player)
        return None

    def ghost_y(self) -> int:
        p = dict(self.piece)
        while self._fits(dict(p, y=p["y"] + 1)):
            p["y"] += 1
        return p["y"]

    def state(self) -> dict:
        self.step()
        return {"well": [["" if c is None else c for c in row] for row in self.well],
                "piece": {**self.piece, "cells": self._cells(self.piece)} if self.piece else None,
                "ghost_y": self.ghost_y() if self.piece and not self.over else None,
                "score": self.score, "lines": self.lines, "level": self.level}

    def voice_words(self) -> list[str]:
        return ["left", "right", "rotate", "down", "drop", "again"]

    def frame_at(self, size: int, t: float):
        import time as _time
        self.step()
        c = blank(size)
        big = size > 96
        cell = 3 if not big else 9
        x0 = (size - self.W * cell) // 2 - (0 if not big else 14)
        y0 = (size - self.H * cell) // 2
        fill(c, x0 - 1, y0, 1, self.H * cell, EDGE)
        fill(c, x0 + self.W * cell, y0, 1, self.H * cell, EDGE)
        fill(c, x0 - 1, y0 + self.H * cell, self.W * cell + 2, 1, EDGE)
        for y, row in enumerate(self.well):
            for x, kind in enumerate(row):
                if kind:
                    tile(c, x0 + x * cell, y0 + y * cell, cell, cell, COLOURS[kind], 3 if big else 1, r=0 if not big else 1)
        if self.cleared and _time.monotonic() - self.cleared[1] < 0.25:
            for y in self.cleared[0]:
                fill(c, x0, y0 + y * cell, self.W * cell, cell, WHITE)
        if self.piece and not self.over:
            gy = self.ghost_y()
            for x, y in self._cells(dict(self.piece, y=gy)):
                if 0 <= y < self.H:
                    outline(c, x0 + x * cell, y0 + y * cell, cell, cell, mix(COLOURS[self.piece["kind"]], BLACK, 0.55), 0, 1)
            for x, y in self._cells(self.piece):
                if 0 <= y < self.H:
                    tile(c, x0 + x * cell, y0 + y * cell, cell, cell, COLOURS[self.piece["kind"]], 3 if big else 1,
                         r=0 if not big else 1)
        if big:
            px = x0 + self.W * cell + 8
            text(c, "NEXT", px, y0 + 2, DIM, 1)
            nxt = self.bag[-1] if self.bag else None
            if nxt:
                for x, y in PIECES[nxt]:
                    tile(c, px + x * 6, y0 + 12 + y * 6, 6, 6, COLOURS[nxt], 3, r=1)
            text(c, str(self.score), px, y0 + 40, INK, 1)
            text(c, f"{self.lines} ln", px, y0 + 50, DIM, 1)
            text(c, f"L{self.level}", px, y0 + 60, DIM, 1)
        else:
            text(c, str(self.score), 2, 2, DIM, 1)
        if self.over:
            banner(c, size, f"{self.score}. again?", INK, (40, 30, 30))
        return c

