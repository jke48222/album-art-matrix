#!/usr/bin/env python3
"""Every game's board at 64 and 192, as one contact sheet, for looking at
the design without a wall. Each game is started with a fixed seed, given
a few moves, and drawn at two moments.

    .venv/bin/python scripts/render_games.py out.png
"""
from __future__ import annotations

import os
import random
import sys
import tempfile
import time

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from brain.games import GAMES                                                      # noqa: E402
from brain.games.host import GameHost                                              # noqa: E402
from brain.games import (wordle, sudoku, spellingbee, letterboxed, connections,    # noqa: E402,F401
                         strands, crossword, contexto, reaction, whistlebird, pictures, heardle, quiz,
                         twentyq, pictionary, arcade)


class Ctrl:
    def __init__(self, w):
        self.s = {"mode": "art"}
        self.wall = type("W", (), {"width": w})()
        self.now_showing = {}
        self.shown_seq = 0
        self.dirty = type("E", (), {"set": lambda self_: None})()
        self.asker = None
        self.imaginer = None
    def get(self):
        return dict(self.s)
    def apply(self, p):
        self.s.update(p)
        return {}
    def journal_read(self, n):
        return []


def sleeve_path():
    p = os.path.join(tempfile.gettempdir(), "render-games-sleeve.png")
    if not os.path.exists(p):
        img = Image.new("RGB", (600, 600), (236, 214, 182))
        d = ImageDraw.Draw(img)
        d.rectangle((50, 50, 550, 550), fill=(24, 70, 170))
        d.ellipse((170, 170, 430, 430), fill=(248, 196, 40))
        d.rectangle((260, 380, 340, 560), fill=(200, 60, 50))
        img.save(p)
    return p


class FakeImaginer:
    ready = True
    def draw(self, prompt, expanded=None, on_partial=None):
        img = Image.new("RGB", (512, 512), (248, 240, 224))
        d = ImageDraw.Draw(img)
        d.ellipse((90, 140, 420, 430), fill=(110, 120, 140))
        d.rectangle((380, 250, 470, 430), fill=(110, 120, 140))
        return img


class ScriptedAsker:
    ready = True
    model = "scripted"
    cost_usd = 0.0


def setup(name, host):
    """Start the game and make a few moves; return the game."""
    o = {"seed": 7}
    if name == "wordle":
        host.start(name, {"word": "crane"}); host.move(None, {"guess": "slate"}); host.move(None, {"guess": "ocean"})
    elif name == "sudoku":
        host.start(name, {"seed": 2, "difficulty": "medium"}); g = host.game
        e = [i for i in range(81) if g.puzzle[i] == 0]
        host.move(None, {"cell": e[0], "digit": g.solution[e[0]]}); host.move(None, {"cell": e[3], "digit": (g.solution[e[3]] % 9) + 1})
        host.move(None, {"choose": e[5]})
    elif name == "spellingbee":
        host.start(name, {"seed": 2}); g = host.game
        for w in g.answers[:3]: host.move(None, {"word": w})
    elif name == "letterboxed":
        host.start(name, {"seed": 2}); host.move(None, {"word": host.game.par[0]})
    elif name == "connections":
        host.start(name, {"set": 2}); g = host.game
        host.move(None, {"words": g.groups[0][1]}); host.move(None, {"pick": g.groups[1][1][0]}); host.move(None, {"pick": g.groups[1][1][1]})
    elif name == "strands":
        host.start(name, {"set": 1, "seed": 2}); g = host.game
        host.move(None, {"word": g.words[0]}); host.move(None, {"word": g.spangram})
    elif name == "crossword":
        host.start(name, {"set": 0}); host.hear("one across is lamp"); host.move(None, {"cell": [1, 0], "letter": "x"}); host.hear("check")
    elif name == "contexto":
        host.start(name, {"word": "guitar"}); host.move(None, {"word": "banana"}); host.move(None, {"word": "piano"})
    elif name == "reaction":
        host.start(name, {"rounds": 3}); g = host.game
        clock = [50.0]; g._clock = lambda: clock[0]; g.begin(); clock[0] = g.t_go + 0.01; g.tick(); host.event("knock", {"t": g.t_go + 0.187})
    elif name == "whistlebird":
        host.start(name, {"seed": 1}); g = host.game
        g.lo, g.hi = 900.0, 1500.0; g.pipes = [[0.55, 0.45, False], [1.15, 0.6, False]]; g.y = 0.42; g.score = 3
    elif name == "sliding":
        host.start(name, {"image": sleeve_path(), "seed": 1})
    elif name == "reveal":
        host.start(name, {"image": sleeve_path(), "title": "Nights", "artist": "Frank Ocean", "album": "Blonde"}); g = host.game
        g._clock = lambda: g.t0 + 14.0
    elif name == "heardle":
        host.start(name, {"title": "Nights", "artist": "Frank Ocean", "preview": "https://example/x.m4a"}); host.move(None, {"skip": True}); host.move(None, {"played": True})
    elif name == "quiz":
        host.start(name, {"set": 0}); g = host.game; g.t_q = g._clock() - 6.0
    elif name == "twentyq":
        twentyq.ask_claude = lambda a, h, salt=0.0: {"question": "Is it something you could hold in one hand?"}
        host.start(name, {"asker": ScriptedAsker()}); host.move(None, {"answer": "yes"})
    elif name == "pictionary":
        host.start(name, {"word": "elephant", "imaginer": FakeImaginer()}); g = host.game
        for _ in range(100):
            if not g.drawing: break
            time.sleep(0.02)
        g._clock = lambda: g.t0 + 20.0
    elif name == "pong":
        host.start(name, {"seed": 1}); g = host.game; g.score = [3, 2]; g.ball = [0.6, 0.35]; g.paddles = [0.3, 0.6]; g.wait_until = 0
    elif name == "snake":
        host.start(name, {"seed": 1}); g = host.game; g.body = [(16 + k, 12) for k in range(9)]; g.dir = (-1, 0); g.food = (8, 20); g.score = 6
    elif name == "tetris":
        host.start(name, {"seed": 3}); g = host.game
        for m in ("left", "left", "rotate", "drop", "right", "right", "drop", "rotate", "drop"): host.move(None, {"move": m})
    return host.game


def main(out: str):
    names = [n for n in ["wordle", "connections", "sudoku", "spellingbee", "letterboxed", "strands", "crossword",
                         "contexto", "heardle", "sliding", "reveal", "twentyq", "pictionary", "quiz",
                         "whistlebird", "reaction", "pong", "snake", "tetris"] if n in GAMES]
    tiles = []
    for name in names:
        row = []
        for size in (64, 192):
            host = GameHost(Ctrl(size), path=os.path.join(tempfile.gettempdir(), "render-games.json"))
            try:
                g = setup(name, host)
            except Exception as exc:
                print(f"{name} at {size}: {exc}")
                row.append(np.zeros((192, 192, 3), np.uint8)); continue
            if g is None:
                print(f"{name} at {size}: did not start"); row.append(np.zeros((192, 192, 3), np.uint8)); continue
            frames = []
            for age in (0.15, 3.0):
                g.changed_at = time.monotonic() - age
                f = host.frame_at(size, time.monotonic())
                frames.append(np.asarray(Image.fromarray(f).resize((192, 192), Image.NEAREST)))
            row.append(np.concatenate(frames, axis=1))
        tiles.append((name, row))
    # the sheet: a row per game, 64 (x3) twice, then 192 twice, with labels
    cell = 192
    W = 4 * cell + 5 * 6 + 70
    H = len(tiles) * (cell + 6) + 6
    sheet = Image.new("RGB", (W, H), (18, 18, 20))
    d = ImageDraw.Draw(sheet)
    for i, (name, row) in enumerate(tiles):
        y = 6 + i * (cell + 6)
        d.text((6, y + 4), name, fill=(200, 200, 200))
        x = 70
        for block in row:
            im = Image.fromarray(block)
            sheet.paste(im, (x, y))
            x += im.size[0] + 6
    sheet.save(out)
    print(f"wrote {out}: {len(tiles)} games")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "games-sheet.png")
