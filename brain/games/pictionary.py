"""AI pictionary.

The wall picks a secret word and has the image model draw it, plainly,
with no text; the picture goes up and everyone guesses, by voice or on
the phone, for sixty seconds. The first right guess wins. The drawing
comes through brain/imagine.py (Services > Images sets the drawer and its
key; without one the game says so). Words come from the wall's own list
of things a drawing can show. Options: {"word": w}, {"seconds": s},
{"seed": n}, {"imaginer": obj} for a test.
"""
from __future__ import annotations

import random
import threading
import time

import numpy as np
from PIL import Image

from . import Game, register
from .board import (BLACK, DIM, GREEN, INK, WHITE, YELLOW, banner, blank, breathe, disc, fill, header, mix,
                    progress, scale_for, text_centred, fit_text)
from ..art.pipeline import prepare
from .pictures import _fold

WORDS = ["elephant", "lighthouse", "bicycle", "umbrella", "cactus", "penguin", "rocket", "snowman", "guitar",
         "octopus", "pineapple", "castle", "windmill", "dragon", "sailboat", "giraffe", "teapot", "volcano",
         "butterfly", "anchor", "mushroom", "robot", "pumpkin", "hot air balloon", "tractor", "flamingo",
         "igloo", "saxophone", "koala", "submarine", "sunflower", "hammock", "kangaroo", "telescope", "waffle",
         "crab", "camel", "typewriter", "lantern", "hedgehog", "carousel", "toucan", "pretzel", "canoe",
         "owl", "cupcake", "scarecrow", "peacock", "skateboard", "walrus", "accordion", "beehive", "compass",
         "dinosaur", "helicopter", "jellyfish", "lobster", "parachute", "sushi", "tent", "unicorn", "zebra"]
SECONDS = 60.0


@register
class Pictionary(Game):
    name = "pictionary"
    title = "AI pictionary"
    blurb = "The wall draws a secret word. Guess it in sixty seconds."
    min_players = 1
    max_players = 8

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        self.imaginer = self.options.get("imaginer") or getattr(getattr(self.host, "ctrl", None), "imaginer", None)
        if self.imaginer is None or not getattr(self.imaginer, "ready", False):
            raise RuntimeError("AI pictionary needs an image key (Services > Images)")
        self.word = str(self.options.get("word") or rng.choice(WORDS)).lower()
        self.seconds = float(self.options.get("seconds", SECONDS))
        self.picture: Image.Image | None = None
        self.faces: dict[int, np.ndarray] = {}
        self.problem: str | None = None
        self.t0: float | None = None
        self._clock = time.monotonic
        self.guesses: list[tuple[str, str]] = []
        self.message = "Drawing."
        self.drawing = True
        threading.Thread(target=self._draw, name="pictionary", daemon=True).start()

    def _draw(self):
        try:
            prompt = (f"A simple, clear drawing of a {self.word}, the whole thing in view, centred, bold "
                      f"outlines and flat colours on a plain background, no words or letters anywhere.")
            self.picture = self.imaginer.draw(f"a {self.word}", expanded=prompt)
            self.t0 = self._clock()
            self.message = "Guess."
        except Exception as exc:
            self.problem = str(exc)
            self.finish(won=False, message=f"Could not draw: {self.problem[:80]}")
            return
        finally:
            self.drawing = False
        self.changed()

    def elapsed(self) -> float:
        return 0.0 if self.t0 is None else self._clock() - self.t0

    def tick(self):
        if not self.over and self.t0 is not None and self.elapsed() >= self.seconds:
            self.finish(won=False, message=f"Time. It was a {self.word}.")

    def apply(self, move: dict, player: str) -> dict:
        return self.guess(str(move.get("guess") or move.get("word") or move.get("text") or ""), player)

    def hear(self, text: str, player: str) -> dict | None:
        if len(text.strip()) < 2:
            return None
        return self.guess(text, player)

    def guess(self, text: str, player: str) -> dict:
        self.tick()
        if self.over:
            return {"error": "the game is over"}
        if self.t0 is None:
            return {"error": "still drawing"}
        g = _fold(text)
        if not g:
            return {"error": "say a word"}
        self.guesses.append((text, player))
        hit = g == self.word or (len(g) > 3 and (g in self.word or self.word in g)) \
            or g.rstrip("s") == self.word.rstrip("s")
        if hit:
            secs = round(self.elapsed(), 1)
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"{player}: {self.word}, at {secs} s.")
            return {"hit": True, "seconds": secs}
        self.message = f"Not {text}."
        self.changed()
        return {"hit": False}

    def state(self) -> dict:
        self.tick()
        return {"drawing": self.drawing, "elapsed": round(self.elapsed(), 1), "seconds": self.seconds,
                "guesses": [{"text": g, "who": p} for g, p in self.guesses],
                "word": self.word if self.over else None, "problem": self.problem}

    def voice_words(self) -> list[str]:
        return list(WORDS)

    def frame_at(self, size: int, t: float):
        self.tick()
        s = scale_for(size)
        if self.picture is None:
            c = blank(size)
            # three dots breathing while the model draws
            for k in range(3):
                b = breathe(t + k * 0.3, 1.2)
                disc(c, size // 2 + (k - 1) * 6 * s, size // 2, (1.0 + 1.2 * b) * s, mix(DIM, INK, b))
            text_centred(c, "drawing", size // 2, size // 2 + 8 * s, DIM, s)
            header(c, size, "PICTIONARY", "", s, accent=YELLOW)
            return c
        if size not in self.faces:
            self.faces[size] = np.asarray(prepare(self.picture, size, unsharp_percent=0), dtype=np.uint8)
        f = self.faces[size].copy()
        if self.over:
            banner(f, size, f"a {self.word}" if not self.won else f"{self.winner or self.players[0]}: {self.word}",
                   INK, mix(GREEN, BLACK, 0.55) if self.won else (40, 40, 30))
        else:
            frac = min(1.0, self.elapsed() / self.seconds)
            progress(f, 0, size - s, size, s, 1.0 - frac, WHITE, (20, 20, 24))
        return f

