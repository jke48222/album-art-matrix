"""The arcade: Pong, Snake and Tetris on the wall.

Pong: two paddles, a ball, first to seven. Each player's phone is a
paddle: tilt it, or slide a finger, and it posts where the paddle should
be ({"paddle": 0..1}) many times a second. One player plays the wall,
which returns the ball with a little error. The court is the panel.

Snake: the wall runs it; the phone is the remote ({"dir": "up" | "down"
| "left" | "right"}, or the same words said). A 26-cell grid, so every
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
            who = self.players[scorer] if scorer < len(self.players) else "the wall"
            self.finish(won=scorer == 0 if len(self.players) == 1 else True, winner=winner,
                        message=f"Match to {who}, {max(self.score)} to {min(self.score)}.")
        else:
            self.phase = "point"
            self.wait_until = (self._now() or self.last_t) + 1.2
            who = self.players[scorer] if scorer < len(self.players) else "the wall"
            self.message = f"Point to {who}, {self.score[0]} to {self.score[1]}."
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

class _ArcadeClock:
    """A stopped display never consumes an unseen round."""
    MAX_DELAY = 0.75
    # The phone polls every 0.1 s during play. If it drops off Wi-Fi or is
    # killed before its own pause request lands, nothing else would stop the
    # render loop from running the round into a wall while the phone says
    # the board is kept. Voice-only play also pauses after this long.
    CONTACT_TIMEOUT = 3.0
    last_contact = None

    @staticmethod
    def _finite(value):
        import math
        try:
            return type(value) in (int, float) and math.isfinite(value)
        except OverflowError:
            return False

    def _now(self):
        value = self._clock()
        return float(value) if self._finite(value) and value >= 0 else None

    def _heard_from_phone(self):
        now = self._now()
        if now is not None:
            self.last_contact = now

    def _wall_active(self):
        ctrl = getattr(self.host, "ctrl", None)
        return not (ctrl is not None and getattr(self.host, "game", None) is self
                    and ctrl.get().get("mode") != "game")

    def _pause(self, reason="Round paused. Your board is saved."):
        if self.phase == "playing":
            self.phase = "paused"
            self.message = reason
            self.changed()

    def _control(self, move):
        if not isinstance(move, dict) or len(move) != 1:
            return {"error": "Send one game command at a time."}
        if set(move) == {"again"}:
            if move["again"] is not True:
                return {"error": "Restart must be true."}
            self.setup()
            self.changed()
            return {"again": True}
        if self.over:
            return {"error": "This round is finished. Start another from the results."}
        command = next(iter(move))
        if command not in ("start", "pause", "resume"):
            return None
        if move[command] is not True:
            return {"error": "Game controls must be true."}
        if command == "pause":
            self.step()
            if self.phase != "playing":
                return {"error": "There is no moving round to pause."}
            self._pause()
            return {"paused": True}
        now = self._now()
        expected = "ready" if command == "start" else "paused"
        if self.phase != expected:
            return {"error": "Start a ready round, or resume a paused one."}
        if now is None or not self._wall_active():
            return {"error": "Return this game to the wall before playing."}
        self.phase = "playing"
        self._reset_timing(now)
        self.message = "Follow the fruit." if self.name == "snake" else "Make room for the next piece."
        self.changed()
        return {"started" if command == "start" else "resumed": True}

    def _tick_time(self, previous):
        if self.over or self.phase != "playing":
            return None
        if not self._wall_active():
            self._pause("Your board is saved while the wall shows something else.")
            return None
        now = self._now()
        if now is None or now < previous or now - previous > self.MAX_DELAY:
            self._pause("Your board paused while the wall caught up. Resume when you’re ready.")
            return None
        if self.last_contact is not None and now - self.last_contact > self.CONTACT_TIMEOUT:
            self._pause("Paused while your phone reconnects.")
            return None
        return now


@register
class Snake(_ArcadeClock, Game):
    name = "snake"
    title = "Snake"
    blurb = "Steer the snake to the fruit. Avoid the edges and your trail."
    min_players = max_players = 1
    # 26 cells over 52 of 64 LEDs: exactly two LEDs a cell at 64 and six at
    # 192. A 32-cell grid gave uneven one- and two-LED cells at 64.
    N = 26
    GRID = (6 / 64, 11 / 64, 52 / 64)
    COLOURS = {"ground": (13, 24, 20), "board": (20, 37, 28), "checker": (24, 42, 32),
               "edge": (68, 92, 65), "tail": (77, 124, 75), "body": (153, 207, 133),
               "head": (225, 244, 176), "fruit": (249, 133, 112), "white": (255, 255, 255)}

    def setup(self):
        pace = self.options.get("step", 0.16)
        if not self._finite(pace) or not 0.07 <= pace <= 0.5:
            raise ValueError("Choose a step duration from 0.07 to 0.5 seconds.")
        self.rng = random.Random(self.options.get("seed"))
        self._clock = getattr(self, "_clock", time.monotonic)
        now = self._now()
        if now is None:
            raise ValueError("The game clock is unavailable.")
        self.over = self.won = False
        self.winner = self.finished = None
        self.phase, self.reason = "ready", ""
        mid = self.N // 2
        self.body = [(mid, mid), (mid - 1, mid), (mid - 2, mid)]
        self.dir = self.next_dir = (1, 0)
        self.turns = []
        self.food = self._food()
        self.score = 0
        self.step_s = float(pace)
        self.last_step = self.last_sample = self.last_contact = now
        self.message = "Start when you’re ready. Swipe or use the arrows."

    def _reset_timing(self, now):
        self.last_step = self.last_sample = now
        self.turns = []
        self.next_dir = self.dir

    def _food(self):
        occupied = set(self.body)
        free = [(x, y) for y in range(self.N) for x in range(self.N) if (x, y) not in occupied]
        return self.rng.choice(free) if free else None

    def _end(self, reason):
        self.phase, self.reason = "finished", reason
        message = ("The board is full. You win." if reason == "filled" else
                   f"{self.score} fruit collected. " + ("The trail crossed itself." if reason == "self" else "The trail reached the edge."))
        self.finish(won=reason == "filled", message=message)

    def apply(self, move, player):
        self._heard_from_phone()
        result = self._control(move)
        if result is not None:
            return result
        key = next(iter(move))
        value = move[key]
        if key not in ("dir", "direction") or not isinstance(value, str) or value.lower() not in DIRS:
            return {"error": "Choose up, down, left or right."}
        self.step()
        if self.over:
            # A turn that lands just as the round ends is not a mistake. An
            # error here stayed on the phone's results screen.
            return {"over": True}
        if self.phase != "playing":
            return {"error": "Start or resume the round before turning."}
        d = DIRS[value.lower()]
        previous = self.turns[-1] if self.turns else self.dir
        if d == previous:
            return {"dir": d, "queued": len(self.turns), "accepted": False}
        if d == (-previous[0], -previous[1]):
            return {"error": "The snake cannot turn straight back into itself.", "dir": previous}
        if len(self.turns) >= 2:
            return {"error": "Two turns are already queued. Let the trail catch up."}
        self.turns.append(d)
        self.next_dir = self.turns[0]
        self.changed()
        return {"dir": d, "queued": len(self.turns), "accepted": True}

    def hear(self, text, player):
        if not isinstance(text, str):
            return None
        word = text.lower().strip(" .!")
        if word in DIRS:
            return self.apply({"dir": word}, player)
        if word in ("start", "pause", "resume", "again", "restart"):
            return self.apply({"again" if word == "restart" else word: True}, player)
        return None

    def step(self):
        now = self._tick_time(self.last_sample)
        if now is None:
            return
        self.last_sample = now
        # The bounded elapsed interval and validated minimum pace bound this loop.
        while not self.over and now - self.last_step + 1e-9 >= self.step_s:
            self.last_step += self.step_s
            if self.turns:
                self.dir = self.turns.pop(0)
            self.next_dir = self.turns[0] if self.turns else self.dir
            hx, hy = self.body[0]
            new = (hx + self.dir[0], hy + self.dir[1])
            grows = new == self.food
            if not (0 <= new[0] < self.N and 0 <= new[1] < self.N):
                self._end("wall")
                return
            if new in (self.body if grows else self.body[:-1]):
                self._end("self")
                return
            self.body.insert(0, new)
            if grows:
                self.score += 1
                self.step_s = max(0.07, self.step_s * 0.97)
                self.food = self._food()
                if self.food is None:
                    self._end("filled")
                    return
                self.message = f"{self.score} fruit collected. Keep growing."
            else:
                self.body.pop()
            self.changed()

    def state(self):
        self._heard_from_phone()
        self.step()
        return {"body": [list(p) for p in self.body], "food": list(self.food) if self.food else None,
                "score": self.score, "n": self.N, "phase": self.phase, "reason": self.reason,
                "direction": next(key for key, value in DIRS.items() if value == self.dir),
                "queued": len(self.turns), "step_seconds": self.step_s,
                "grid": {"x": self.GRID[0], "y": self.GRID[1], "size": self.GRID[2]},
                "sample_time": self.last_sample}

    def voice_words(self):
        return list(DIRS) + ["start", "pause", "resume", "again"]

    def frame_at(self, size, t):
        from .board import rect
        self.step()
        c = blank(size)
        p = self.COLOURS
        c[:] = p["ground"]
        u = size / 64
        x0, y0, span = [value * size for value in self.GRID]
        cell = span / self.N
        rect(c, round(x0 - u), round(y0 - u), round(span + 2 * u), round(span + 2 * u), p["edge"], max(1, round(u / 2)))
        for y in range(self.N):
            for x in range(self.N):
                x1, y1 = round(x0 + x * cell), round(y0 + y * cell)
                fill(c, x1, y1, round(x0 + (x + 1) * cell) - x1,
                     round(y0 + (y + 1) * cell) - y1, p["checker"] if (x + y) % 2 else p["board"])
        for index, (x, y) in enumerate(reversed(self.body)):
            col = mix(p["tail"], p["body"], (index + 1) / len(self.body))
            x1, y1 = round(x0 + x * cell), round(y0 + y * cell)
            fill(c, x1, y1, max(1, round(x0 + (x + 1) * cell) - x1), max(1, round(y0 + (y + 1) * cell) - y1), col)
        hx, hy = self.body[0]
        x1, y1 = round(x0 + hx * cell), round(y0 + hy * cell)
        w, h = round(x0 + (hx + 1) * cell) - x1, round(y0 + (hy + 1) * cell) - y1
        fill(c, x1, y1, w, h, p["head"])
        if cell >= 4:
            # Two eyes show direction independently of colour.
            dx, dy = self.dir
            for side in (-1, 1):
                ex = x0 + (hx + 0.5 + dx * 0.22 - dy * side * 0.22) * cell
                ey = y0 + (hy + 0.5 + dy * 0.22 + dx * side * 0.22) * cell
                disc(c, ex, ey, max(0.5, cell * 0.09), p["ground"])
        if self.food:
            fx, fy = self.food
            disc(c, x0 + (fx + 0.5) * cell, y0 + (fy + 0.5) * cell, max(1, cell * 0.48), p["fruit"])
            if cell >= 4:
                fill(c, round(x0 + (fx + 0.5) * cell), round(y0 + fy * cell), max(1, round(cell * 0.15)), max(1, round(cell * 0.25)), p["head"])
        label = {"ready": "READY", "paused": "PAUSE", "finished": "FINAL"}.get(self.phase, "SNAKE")
        scale = max(1, size // 64)
        text(c, label, round(6 * u), round(1 * u), p["white"], scale)
        text_right(c, str(self.score), round(59 * u), round(1 * u), p["head"], scale)
        return c


PIECES = {
    "I": [(0, 1), (1, 1), (2, 1), (3, 1)], "O": [(1, 0), (2, 0), (1, 1), (2, 1)],
    "T": [(1, 0), (0, 1), (1, 1), (2, 1)], "S": [(1, 0), (2, 0), (0, 1), (1, 1)],
    "Z": [(0, 0), (1, 0), (1, 1), (2, 1)], "J": [(0, 0), (0, 1), (1, 1), (2, 1)],
    "L": [(2, 0), (0, 1), (1, 1), (2, 1)],
}
COLOURS = {"I": (117, 204, 218), "O": (245, 205, 111), "T": (177, 148, 221),
           "S": (151, 202, 142), "Z": (230, 132, 135), "J": (128, 169, 225), "L": (236, 169, 112)}


def rotated(cells, times: int):
    out = list(cells)
    if set(cells) == set(PIECES["O"]):
        return out
    centre = 3 if len({x for x, _ in cells}) == 4 or len({y for _, y in cells}) == 4 else 2
    for _ in range(times % 4):
        out = [(centre - y, x) for x, y in out]
    return out


_ARCADE_GLYPHS = {
    "0": ("111", "101", "101", "101", "111"), "1": ("010", "110", "010", "010", "111"),
    "2": ("111", "001", "111", "100", "111"), "3": ("111", "001", "111", "001", "111"),
    "4": ("101", "101", "111", "001", "001"), "5": ("111", "100", "111", "001", "111"),
    "6": ("111", "100", "111", "101", "111"), "7": ("111", "001", "010", "010", "010"),
    "8": ("111", "101", "111", "101", "111"), "9": ("111", "101", "111", "001", "111"),
    "A": ("010", "101", "111", "101", "101"), "D": ("110", "101", "101", "101", "110"),
    "E": ("111", "100", "110", "100", "111"), "F": ("111", "100", "110", "100", "100"),
    "I": ("111", "010", "010", "010", "111"), "L": ("100", "100", "100", "100", "111"),
    "M": ("101", "111", "111", "101", "101"), "N": ("110", "101", "101", "101", "101"),
    "P": ("110", "101", "110", "100", "100"), "R": ("110", "101", "110", "101", "101"),
    "S": ("111", "100", "111", "001", "111"), "T": ("111", "010", "010", "010", "010"),
    "U": ("101", "101", "101", "101", "111"), "V": ("101", "101", "101", "101", "010"),
    "X": ("101", "101", "010", "101", "101"), "Y": ("101", "101", "010", "010", "010"),
    "+": ("000", "010", "111", "010", "000"),
}


def _arcade_text(canvas, label, x, y, colour, scale=1):
    for index, character in enumerate(label):
        for row, pixels in enumerate(_ARCADE_GLYPHS[character]):
            for column, lit in enumerate(pixels):
                if lit == "1":
                    fill(canvas, x + (index * 4 + column) * scale, y + row * scale, scale, scale, colour)


def _arcade_value(value):
    if value < 1_000_000:
        return str(value)
    return str(value // 1_000_000) + "M" if value < 100_000_000_000 else "99999+"


@register
class Tetris(_ArcadeClock, Game):
    name = "tetris"
    title = "Tetris"
    blurb = "Fit falling pieces into full rows."
    min_players = max_players = 1
    W, H = 10, 20
    LOCK_DELAY = 0.5
    MAX_LOCK_RESETS = 15
    WELL = (4 / 64, 2 / 64, 3 / 64)
    PALETTE = {"ground": (17, 20, 31), "well": (24, 29, 44), "grid": (35, 42, 57),
               "edge": (88, 98, 119), "dim": (155, 167, 188), "white": (255, 255, 255)}
    KICKS = (((0, 0), (-1, 0), (-1, -1), (0, 2), (-1, 2)),
             ((0, 0), (1, 0), (1, 1), (0, -2), (1, -2)),
             ((0, 0), (1, 0), (1, -1), (0, 2), (1, 2)),
             ((0, 0), (-1, 0), (-1, 1), (0, -2), (-1, -2)))
    I_KICKS = (((0, 0), (-2, 0), (1, 0), (-2, 1), (1, -2)),
               ((0, 0), (-1, 0), (2, 0), (-1, -2), (2, 1)),
               ((0, 0), (2, 0), (-1, 0), (2, -1), (-1, 2)),
               ((0, 0), (1, 0), (-2, 0), (1, 2), (-2, -1)))

    def setup(self):
        self.rng = random.Random(self.options.get("seed"))
        self._clock = getattr(self, "_clock", time.monotonic)
        now = self._now()
        if now is None:
            raise ValueError("The game clock is unavailable.")
        self.over = self.won = False
        self.winner = self.finished = None
        self.phase, self.reason = "ready", ""
        self.well = [[None] * self.W for _ in range(self.H)]
        self.bag = []
        self.score = self.lines = self.last_clear = self.pieces_placed = 0
        self.level = 1
        self.last_fall = self.last_sample = self.last_contact = now
        self.piece = self.cleared = None
        self.grounded_since = None
        self.lock_resets = 0
        self._spawn(now)
        self.message = "Start when you’re ready. Turn, place, and clear."

    def _reset_timing(self, now):
        self.last_fall = self.last_sample = now
        self.grounded_since = now if self.piece and not self._fits(dict(self.piece, y=self.piece["y"] + 1)) else None

    def _refill_bag(self):
        if not self.bag:
            self.bag = list(PIECES)
            self.rng.shuffle(self.bag)

    def _next_kind(self):
        self._refill_bag()
        kind = self.bag.pop()
        self._refill_bag()  # The preview remains available across every bag boundary.
        return kind

    def _spawn(self, now=None):
        self.piece = {"kind": self._next_kind(), "x": 3, "y": 0, "r": 0}
        self.grounded_since, self.lock_resets = None, 0
        now = self._now() if now is None else now
        if now is not None:
            self.last_fall = now
        if not self._fits(self.piece):
            self._end("stack")

    def _end(self, reason):
        self.phase, self.reason = "finished", reason
        self.finish(won=False, message=f"{self.lines} lines. {self.score} points. The stack reached the top.")

    def _cells(self, piece):
        return [(piece["x"] + x, piece["y"] + y) for x, y in rotated(PIECES[piece["kind"]], piece["r"])]

    def _fits(self, piece):
        return all(0 <= x < self.W and -4 <= y < self.H and (y < 0 or self.well[y][x] is None)
                   for x, y in self._cells(piece))

    def _lock(self, now=None):
        if self.over:
            return
        now = self._now() if now is None else now
        if now is None:
            self._pause("The board paused while the wall caught up.")
            return
        cells = self._cells(self.piece)
        if any(y < 0 for _, y in cells):
            self._end("ceiling")
            return
        for x, y in cells:
            self.well[y][x] = self.piece["kind"]
        self.pieces_placed += 1
        full = [y for y, row in enumerate(self.well) if all(row)]
        self.last_clear = len(full)
        if full:
            self.cleared = (list(full), now)
            survivors = [row for index, row in enumerate(self.well) if index not in full]
            self.well = [[None] * self.W for _ in full] + survivors
            self.score += (0, 100, 300, 500, 800)[len(full)] * self.level
            self.lines += len(full)
            self.level = 1 + self.lines // 10
            self.message = f"{len(full)} {'line' if len(full) == 1 else 'lines'} cleared. {self.score} points."
        else:
            self.message = "Placed. Make room for the next piece."
        self._spawn(now)
        self.changed()

    def fall_s(self):
        return max(0.08, 0.8 * 0.85 ** min(100, self.level - 1))

    def _ground(self, now, reset=False):
        grounded = not self._fits(dict(self.piece, y=self.piece["y"] + 1))
        if not grounded:
            self.grounded_since = None
        elif self.grounded_since is None:
            self.grounded_since = now
        elif reset and self.lock_resets < self.MAX_LOCK_RESETS:
            self.grounded_since = now
            self.lock_resets += 1

    def _down(self, now=None):
        now = self._now() if now is None else now
        piece = dict(self.piece, y=self.piece["y"] + 1)
        moved = self._fits(piece)
        if moved:
            self.piece = piece
        self._ground(now)
        return moved

    def step(self):
        now = self._tick_time(self.last_sample)
        if now is None:
            return
        self.last_sample = now
        while now - self.last_fall + 1e-9 >= self.fall_s():
            at = self.last_fall + self.fall_s()
            if self.grounded_since is not None and at >= self.grounded_since + self.LOCK_DELAY:
                self._lock(now)
                return
            self.last_fall = at
            self._down(at)
            self.changed()
        if self.grounded_since is not None and now + 1e-9 >= self.grounded_since + self.LOCK_DELAY:
            self._lock(now)

    def apply(self, move, player):
        self._heard_from_phone()
        result = self._control(move)
        if result is not None:
            return result
        key = next(iter(move))
        value = move[key]
        if key not in ("move", "dir") or not isinstance(value, str) or value.lower() not in ("left", "right", "rotate", "down", "drop"):
            return {"error": "Choose left, right, rotate, down or drop."}
        self.step()
        if self.over:
            # A move that lands just as the stack tops out is not a mistake.
            return {"over": True}
        if self.phase != "playing":
            return {"error": "Start or resume the round before moving."}
        now = self._now()
        if now is None:
            return {"error": "The game clock is unavailable."}
        command = value.lower()
        moved = False
        if command in ("left", "right"):
            candidate = dict(self.piece, x=self.piece["x"] + (1 if command == "right" else -1))
            if self._fits(candidate):
                self.piece, moved = candidate, True
                self._ground(now, reset=True)
        elif command == "rotate":
            if self.piece["kind"] != "O":
                kicks = self.I_KICKS if self.piece["kind"] == "I" else self.KICKS
                for dx, dy in kicks[self.piece["r"]]:
                    candidate = dict(self.piece, r=(self.piece["r"] + 1) % 4,
                                     x=self.piece["x"] + dx, y=self.piece["y"] + dy)
                    if self._fits(candidate):
                        self.piece, moved = candidate, True
                        self._ground(now, reset=True)
                        break
        elif command == "down":
            moved = self._down(now)
            if moved:
                self.score += 1
                self.last_fall = now
        else:
            landing = self.ghost_y()
            distance = max(0, landing - self.piece["y"])
            self.score += distance * 2  # Include drop points in a possible final receipt.
            self.piece = dict(self.piece, y=landing)
            self._lock(now)
            moved = True
        self.changed()
        return {"move": command, "moved": moved, "piece": dict(self.piece)}

    def hear(self, text, player):
        if not isinstance(text, str):
            return None
        word = text.lower().strip(" .!")
        word = {"turn": "rotate", "spin": "rotate", "fall": "drop", "slam": "drop", "restart": "again"}.get(word, word)
        if word in ("left", "right", "rotate", "down", "drop"):
            return self.apply({"move": word}, player)
        if word in ("start", "pause", "resume", "again"):
            return self.apply({word: True}, player)
        return None

    def ghost_y(self):
        piece = dict(self.piece)
        while self._fits(dict(piece, y=piece["y"] + 1)):
            piece["y"] += 1
        return piece["y"]

    def state(self):
        self._heard_from_phone()
        self.step()
        next_kind = self.bag[-1]
        return {"well": [[cell or "" for cell in row] for row in self.well],
                "piece": {**self.piece, "cells": [list(p) for p in self._cells(self.piece)]},
                "ghost_y": self.ghost_y() if not self.over else None,
                "next": {"kind": next_kind, "cells": [list(p) for p in PIECES[next_kind]]},
                "score": self.score, "lines": self.lines, "level": self.level,
                "score_display": _arcade_value(self.score), "lines_display": _arcade_value(self.lines), "level_display": _arcade_value(self.level),
                "phase": self.phase, "reason": self.reason, "last_clear": self.last_clear,
                "pieces_placed": self.pieces_placed, "grounded": self.grounded_since is not None,
                "well_geometry": {"x": self.WELL[0], "y": self.WELL[1], "cell": self.WELL[2]},
                "sample_time": self.last_sample}

    def voice_words(self):
        return ["left", "right", "rotate", "down", "drop", "start", "pause", "resume", "again"]

    def frame_at(self, size, t):
        from .board import rect
        self.step()
        c = blank(size)
        p = self.PALETTE
        c[:] = p["ground"]
        u = size / 64
        x0, y0, cell = [value * size for value in self.WELL]
        fill(c, round(x0), round(y0), round(cell * self.W), round(cell * self.H), p["well"])
        stroke = max(1, round(u / 3))
        rect(c, round(x0 - u), round(y0 - u), round(cell * self.W + 2 * u), round(cell * self.H + 2 * u), p["edge"], stroke)
        if size >= 128:
            for y in range(1, self.H):
                fill(c, round(x0), round(y0 + y * cell), round(cell * self.W), stroke, p["grid"])
            for x in range(1, self.W):
                fill(c, round(x0 + x * cell), round(y0), stroke, round(cell * self.H), p["grid"])

        def block(x, y, kind, ghost=False, origin=None, width=None):
            if y < 0:
                return
            ox, oy = origin or (x0, y0)
            unit = width or cell
            px, py = round(ox + x * unit), round(oy + y * unit)
            side = max(1, round(unit) - (1 if unit >= 6 else 0))
            colour = COLOURS[kind]
            if ghost:
                rect(c, px, py, side, side, mix(colour, p["well"], 0.35), stroke)
                return
            fill(c, px, py, side, side, colour)
            if unit >= 6:
                fill(c, px, py, side, stroke, mix(colour, p["white"], 0.35))
                fill(c, px, py + side - stroke, side, stroke, mix(colour, p["ground"], 0.35))
            # Each piece has a stable inset glyph as a colour-independent cue.
            if unit >= 14:
                text(c, kind, px + (side - 5) // 2, py + (side - 7) // 2, p["ground"], 1)

        for y, row in enumerate(self.well):
            for x, kind in enumerate(row):
                if kind:
                    block(x, y, kind)
        if self.piece and not self.over:
            for x, y in self._cells(dict(self.piece, y=self.ghost_y())):
                block(x, y, self.piece["kind"], True)
            for x, y in self._cells(self.piece):
                block(x, y, self.piece["kind"])
        sx = round(40 * u)
        label = {"ready": "READY", "paused": "PAUSED", "finished": "FINAL"}.get(self.phase, "NEXT")
        _arcade_text(c, label, sx, round(3 * u), p["white"], max(1, round(u * 0.55)))
        next_kind = self.bag[-1]
        for x, y in PIECES[next_kind]:
            block(x, y, next_kind, origin=(40 * u, 11 * u), width=4 * u)
        for label, number, yy in (("PTS", self.score, 24), ("LINES", self.lines, 37), ("LEVEL", self.level, 50)):
            _arcade_text(c, label, sx, round(yy * u), p["dim"], max(1, round(u * 0.55)))
            digits = _arcade_value(number)
            scale = max(1, min(round(u * 0.8), int(23 * u / (len(digits) * 4 - 1))))
            _arcade_text(c, digits, sx, round((yy + 7) * u), p["white"], scale)
        return c
