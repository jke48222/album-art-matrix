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
from .board import (BLACK, BLUE, DIM, FAINT, GREEN, INK, ORANGE, PURPLE, RED, WHITE, YELLOW, blank, fill,
                    header, scale_for, text, text_centred)

DIRS = {"up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}


@register
class Pong(Game):
    name = "pong"
    title = "Pong"
    blurb = "Your phone is the paddle: tilt it. First to seven."
    min_players = 1
    max_players = 2
    by_voice = False

    def setup(self):
        self.rng = random.Random(self.options.get("seed"))
        self.to = int(self.options.get("to", 7))
        self.paddles = [0.5, 0.5]                # 0 top .. 1 bottom, centre of each paddle
        self.pad_h = 0.22
        self.score = [0, 0]
        self.last_t = time.monotonic()
        self._clock = time.monotonic
        self.serve(self.rng.choice((-1, 1)))
        self.message = "Tilt to move."

    def serve(self, direction: int):
        self.ball = [0.5, 0.5]
        ang = self.rng.uniform(-0.6, 0.6)
        speed = 0.45
        import math
        self.vel = [direction * speed * math.cos(ang), speed * math.sin(ang)]
        self.wait_until = self._clock() + 1.0

    def apply(self, move: dict, player: str) -> dict:
        if "paddle" in move:
            try:
                y = max(0.0, min(1.0, float(move["paddle"])))
            except (TypeError, ValueError):
                return {"error": "paddle from 0 to 1"}
            side = 0 if player == self.players[0] else 1 if len(self.players) > 1 else 0
            if "side" in move and move["side"] in (0, 1):
                side = int(move["side"])
            self.paddles[side] = y
            return {"paddle": y, "side": side}
        if move.get("again"):
            self.score = [0, 0]
            self.over = False
            self.serve(1)
            self.changed()
            return {"again": True}
        return {"error": "paddle, or again"}

    def step(self):
        now = self._clock()
        dt = min(0.05, max(0.0, now - self.last_t))
        self.last_t = now
        if self.over or now < self.wait_until:
            return
        # the wall's own paddle, when there is one player: it follows the ball, imperfectly
        if len(self.players) < 2:
            target = self.ball[1] + self.rng.uniform(-0.06, 0.06)
            self.paddles[1] += (target - self.paddles[1]) * min(1.0, 3.5 * dt)
        x, y = self.ball
        x += self.vel[0] * dt
        y += self.vel[1] * dt
        if y <= 0.0 or y >= 1.0:
            self.vel[1] = -self.vel[1]
            y = max(0.0, min(1.0, y))
        for side, px in ((0, 0.04), (1, 0.96)):
            if (side == 0 and x <= px and self.vel[0] < 0) or (side == 1 and x >= px and self.vel[0] > 0):
                py = self.paddles[side]
                if abs(y - py) <= self.pad_h / 2:
                    self.vel[0] = -self.vel[0] * 1.05
                    self.vel[1] += (y - py) / (self.pad_h / 2) * 0.25
                    x = px
                else:
                    self.score[1 - side] += 1
                    if max(self.score) >= self.to:
                        winner = self.players[self.score.index(max(self.score))] if len(self.players) > 1 else None
                        won = self.score[0] > self.score[1]
                        self.finish(won=won, winner=winner, message=f"{self.score[0]} to {self.score[1]}.")
                    else:
                        self.message = f"{self.score[0]} to {self.score[1]}."
                        self.serve(1 if side == 0 else -1)
                        self.changed()
                    return
        self.ball = [x, y]

    def state(self) -> dict:
        self.step()
        return {"ball": [round(self.ball[0], 3), round(self.ball[1], 3)], "paddles": [round(p, 3) for p in self.paddles],
                "score": self.score, "to": self.to}

    def frame_at(self, size: int, t: float):
        self.step()
        c = blank(size)
        s = scale_for(size)
        for k in range(0, size, 4 * s):
            fill(c, size // 2, k, s, 2 * s, FAINT)
        ph = int(self.pad_h * size)
        for side, x in ((0, s), (1, size - 2 * s)):
            y = int(self.paddles[side] * size) - ph // 2
            fill(c, x, max(0, y), s, ph, INK)
        bx, by = int(self.ball[0] * (size - 2 * s)), int(self.ball[1] * (size - 2 * s))
        fill(c, bx, by, 2 * s, 2 * s, YELLOW)
        text(c, str(self.score[0]), size // 2 - 8 * s, 2 * s, DIM, s)
        text(c, str(self.score[1]), size // 2 + 3 * s, 2 * s, DIM, s)
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
        for i, (x, y) in enumerate(self.body):
            fill(c, x * cell, y * cell, cell, cell, GREEN if i else (120, 220, 90))
        fx, fy = self.food
        fill(c, fx * cell, fy * cell, cell, cell, RED)
        if self.over:
            text_centred(c, "again?", size // 2, size // 2, INK, scale_for(size))
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
        self.step()
        c = blank(size)
        cell = 3 if size <= 96 else 9
        x0 = (size - self.W * cell) // 2
        y0 = (size - self.H * cell) // 2
        fill(c, x0 - 1, y0, 1, self.H * cell, FAINT)
        fill(c, x0 + self.W * cell, y0, 1, self.H * cell, FAINT)
        for y, row in enumerate(self.well):
            for x, kind in enumerate(row):
                if kind:
                    fill(c, x0 + x * cell, y0 + y * cell, cell, cell, COLOURS[kind])
        if self.piece and not self.over:
            gy = self.ghost_y()
            for x, y in self._cells(dict(self.piece, y=gy)):
                if 0 <= y < self.H:
                    fill(c, x0 + x * cell, y0 + y * cell, cell, cell, (40, 40, 46))
            for x, y in self._cells(self.piece):
                if 0 <= y < self.H:
                    fill(c, x0 + x * cell, y0 + y * cell, cell, cell, COLOURS[self.piece["kind"]])
        if size > 96:
            text(c, str(self.score), x0 + self.W * cell + 6, 6, INK, 1)
            text(c, f"L{self.level}", x0 + self.W * cell + 6, 16, DIM, 1)
        if self.over:
            text_centred(c, "again?", size // 2, size // 2, INK, scale_for(size))
        return c
