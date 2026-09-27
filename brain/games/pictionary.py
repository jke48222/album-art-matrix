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

import math
import re
import random
import threading
import time

import numpy as np
from PIL import Image

from . import Game, register
from .board import blank, disc, line, progress, text_centred
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


def accepted_names(word: str) -> set[str]:
    """Whole normalized names and their ordinary plurals, never substrings."""
    parts = word.split()
    singular = parts[-1]
    irregular = {"cactus": ["cacti", "cactuses"], "walrus": ["walruses"]}
    if singular in irregular:
        plurals = irregular[singular]
    elif singular.endswith("y") and len(singular) > 1 and singular[-2] not in "aeiou":
        plurals = [singular[:-1] + "ies"]
    elif singular.endswith(("s", "x", "z", "ch", "sh")):
        plurals = [singular + "es"]
    else:
        plurals = [singular + "s"]
    return {_fold(word)} | {_fold(" ".join(parts[:-1] + [plural])) for plural in plurals}


@register
class Pictionary(Game):
    name = "pictionary"
    title = "AI pictionary"
    blurb = "A picture takes shape. Name it before the minute runs out."
    min_players = 1
    max_players = 8

    def setup(self):
        self.imaginer = self.options.get("imaginer") or getattr(getattr(self.host, "ctrl", None), "imaginer", None)
        if self.imaginer is None or not getattr(self.imaginer, "ready", False):
            raise RuntimeError("AI pictionary needs an image key (Services > Images)")
        requested = self.options.get("word")
        if requested is not None and (not isinstance(requested, str) or not 2 <= len(requested.strip()) <= 48
                                      or not re.fullmatch(r"[a-z]+(?: [a-z]+){0,4}", requested.strip().lower())):
            raise ValueError("choose a short word or phrase using letters A–Z")
        seed = self.options.get("seed")
        if seed is not None and (isinstance(seed, bool) or not isinstance(seed, (int, str))):
            raise ValueError("seed must be an integer or text")
        seconds = self.options.get("seconds", SECONDS)
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 1 <= seconds <= 300:
            raise ValueError("seconds must be a number from 1 to 300")
        self.word = requested.strip().lower() if requested else random.Random(seed).choice(WORDS)
        self.answers = accepted_names(self.word)
        self.seconds = float(seconds)
        self._lock = getattr(self.host, "_lock", threading.RLock())
        self._host_generation = getattr(self.host, "_generation", None)
        self._request = 0
        self.picture: Image.Image | None = None
        self.faces: dict[int, np.ndarray] = {}
        self.problem: str | None = None
        self.t0: float | None = None
        self.finished_elapsed: float | None = None
        self._clock = time.monotonic
        self.guesses: list[tuple[str, str]] = []
        self._tried: set[tuple[str, str]] = set()
        self.receipt = self.drawing_revision = 0
        self.last_guess = None
        self.drawing = False
        with self._lock:
            self._begin_drawing()

    def _owned(self):
        if self.over:
            return False
        if self.host is None or not hasattr(self.host, "game"):
            return True
        return self.host.game is self or (getattr(self.host, "_generation", None) == self._host_generation
                                         and getattr(self.host, "_starting", None) == self.name)

    def _begin_drawing(self):
        self._request += 1
        request = self._request
        self.problem = None
        self.drawing = True
        self.message = "The first lines are on their way. Your timer has not started."
        self.changed()
        threading.Thread(target=self._draw, args=(request,), name="pictionary-drawing", daemon=True).start()

    @staticmethod
    def _master(image):
        if not isinstance(image, Image.Image) or min(image.size) < 8 or image.width * image.height > 40_000_000:
            raise ValueError("the picture was unreadable")
        return prepare(image.convert("RGB"), 512, unsharp_percent=0).copy()

    def _publish(self, request, image, final=False):
        master = self._master(image)  # Never decode or resize while holding the host's lock.
        with self._lock:
            if request != self._request or not self._owned():
                return
            self.tick()
            if self.over:
                return
            self.picture = master
            self.faces = {}
            self.drawing_revision += 1
            if self.t0 is None:
                self.t0 = self._clock()
            self.drawing = not final
            if final:
                self._request += 1  # Late partial callbacks cannot replace the final picture.
            self.message = "Name the picture. Every complete guess counts."
            self.changed()

    def _draw(self, request):
        try:
            prompt = (f"A simple, clear drawing of a {self.word}, the whole thing in view, centred, bold "
                      "outlines and flat colours on a plain background, no words or letters anywhere.")
            image = self.imaginer.draw(f"a {self.word}", expanded=prompt,
                                       on_partial=lambda image: self._publish(request, image))
            self._publish(request, image, final=True)
        except Exception as exc:
            print(f"[games] pictionary provider: {type(exc).__name__}", flush=True)
            with self._lock:
                if request != self._request or not self._owned():
                    return
                self.tick()
                if self.over:
                    return
                self.drawing = False
                self.problem = ("The drawing stopped early. Keep guessing from this sketch." if self.picture else
                                "The picture couldn't be drawn. Try drawing it again; your timer has not started.")
                self.message = "Keep guessing from the sketch." if self.picture else "Try the drawing again."
                self.changed()

    def elapsed(self) -> float:
        if self.finished_elapsed is not None:
            return self.finished_elapsed
        if self.t0 is None:
            return 0.0
        return min(self.seconds, max(0.0, self._clock() - self.t0))

    def finish(self, won=False, winner=None, message=None):
        with self._lock:
            if self.over:
                return
            self.finished_elapsed = self.elapsed()
            self._request += 1
            self.drawing = False
            self.problem = None
            super().finish(won, winner, message)

    def tick(self):
        if not self.over and self.t0 is not None and self.elapsed() >= self.seconds:
            self.finish(won=False, message=f"Time. It was a {self.word}.")

    def apply(self, move: dict, player: str) -> dict:
        with self._lock:
            self.tick()
            if self.over:
                return {"error": "the game is over"}
            if not isinstance(move, dict):
                return {"error": "enter a complete name"}
            if "retry" in move:
                if move != {"retry": True} or type(move["retry"]) is not bool:
                    return {"error": "retry must be true"}
                if self.drawing or not self.problem or self.picture is not None:
                    return {"error": "there is no failed drawing to retry"}
                self._begin_drawing()
                return {"retrying": True}
            keys = set(move)
            if len(keys) != 1 or not keys <= {"guess", "word", "text"}:
                return {"error": "enter one complete name"}
            return self.guess(next(iter(move.values())), player)

    def hear(self, text: str, player: str) -> dict | None:
        return self.guess(text, player) if isinstance(text, str) and len(text.strip()) >= 2 else None

    def guess(self, text: str, player: str) -> dict:
        with self._lock:
            self.tick()
            if self.over:
                return {"error": "the game is over"}
            if self.t0 is None:
                return {"error": "wait for the first lines of the drawing"}
            if not isinstance(text, str) or not 1 <= len(text.strip()) <= 120:
                return {"error": "enter a complete name up to 120 characters"}
            text = text.strip()
            normalized = _fold(text)
            if not normalized:
                return {"error": "say a name"}
            if (normalized, player) in self._tried:
                return {"error": "you already tried that name"}
            self._tried.add((normalized, player))
            self.receipt += 1
            self.guesses.append((text, player))
            del self.guesses[:-80]
            self.last_guess = {"text": text, "who": player, "receipt": self.receipt}
            hit = normalized in self.answers
            if hit:
                seconds = round(self.elapsed(), 1)
                self.finish(won=True, winner=player if len(self.players) > 1 else None,
                            message=f"{player}: {self.word}, at {seconds:g} s.")
                return {"hit": True, "seconds": seconds, "receipt": self.receipt}
            self.message = "Keep looking. Try another complete name."
            self.changed()
            return {"hit": False, "receipt": self.receipt}

    def state(self) -> dict:
        with self._lock:
            self.tick()
            elapsed = self.elapsed()
            return {"drawing": self.drawing, "elapsed": round(elapsed, 1), "seconds": self.seconds,
                    "remaining": round(max(0, self.seconds - elapsed), 1), "picture_ready": self.picture is not None,
                    "phase": "finished" if self.over else "playing" if self.picture else "drawing" if self.drawing else "error",
                    "drawing_revision": self.drawing_revision, "frame_step": int(elapsed),
                    "guesses": [{"text": guess, "who": who} for guess, who in self.guesses[-12:]],
                    "guess_count": self.receipt, "receipt": self.receipt,
                    "last_guess": dict(self.last_guess) if self.last_guess else None,
                    "word": self.word if self.over else None, "problem": self.problem,
                    "can_retry": bool(self.problem) and not self.drawing and self.picture is None and not self.over}

    def voice_words(self) -> list[str]:
        return list(WORDS)

    def frame_at(self, size: int, t: float):
        with self._lock:
            self.tick()
            if self.picture is None:
                canvas = blank(size); canvas[:] = (16, 14, 12)
                cream, muted = (240, 231, 211), (150, 144, 127)
                # A pencil and three first marks; identical normalized geometry
                # at 64, 192 and 512, with no invented progress percentage.
                line(canvas, (size * .34, size * .56), (size * .64, size * .26), cream, max(2, round(size * .065)))
                line(canvas, (size * .31, size * .60), (size * .39, size * .58), (223, 185, 101), max(1, round(size * .018)))
                for index in range(3):
                    disc(canvas, size * (.41 + index * .09), size * .69, max(1, size * .014), muted)
                scale = max(1, round(size * .04 / 7))
                text_centred(canvas, "TRY AGAIN" if self.problem else "DRAWING", size // 2, round(size * .83), cream, scale)
                return canvas
            if size not in self.faces:
                self.faces[size] = np.asarray(self.picture.resize((size, size), Image.Resampling.LANCZOS), dtype=np.uint8).copy()
                while len(self.faces) > 4:
                    self.faces.pop(next(iter(self.faces)))
            frame = self.faces[size].copy()
            if not self.over:
                rail = max(1, round(size * .012))
                progress(frame, 0, size - rail, size, rail, 1 - self.elapsed() / self.seconds,
                         (240, 231, 211), (29, 29, 28), head=None)
            return frame
