"""Two games on a sleeve from the wall's own history.

Sliding picture puzzle: a sleeve the wall has worn, cut into a 3x3 (or
4x4) of blocks with one missing, scrambled by a walk of legal slides so
it can always be put back, and slid back by the phone (tap a block next
to the gap) or by voice ("up" slides the block below the gap up into it,
and so on). The wall and phone share the numbered tiles and legal-move outlines; the
phone keeps the move count and undo beside the artwork.

Cover reveal: a sleeve starts as a blur and sharpens over thirty seconds;
the first to name the album or the artist wins, by voice or by typing.
The blur is the sleeve at the wall's size through a Gaussian whose radius
falls with time, drawn a few times a second. After thirty seconds it is
sharp; the phone identifies the sleeve while the whole image remains visible.

Both take their sleeves from the journal, the last few hundred songs,
skipping the one that is on; a test can hand in an image with
{"image": path}. Options: {"grid": 3 | 4}, {"seed": n}, {"seconds": s}.
"""
from __future__ import annotations

import random
import math
import unicodedata
import re
import time

import numpy as np
from PIL import Image, ImageFilter

from . import Game, register
from .board import blank, fill, rect, line, text, progress
from ..art.fetch import fetch_art
from ..art.pipeline import prepare
from .parking import ParkedClock


def _fold(s: str) -> str:
    """Normalize a complete answer without allowing substring matches."""
    if not isinstance(s, str):
        return ""
    s = unicodedata.normalize("NFKD", s.casefold())
    s = "".join(ch for ch in s if not unicodedata.combining(ch))
    s = re.sub(r"\(.*?\)|\[.*?\]", " ", s)
    s = re.sub(r"\b(feat|ft|featuring)\b.*$", " ", s)
    s = s.replace("’", "").replace("'", "")
    s = "".join(ch if ch.isalnum() or ch.isspace() else " " for ch in s)
    return re.sub(r"^(the|a|an) ", "", " ".join(s.split())).strip()


def _metadata(entry: dict) -> dict:
    return {key: entry.get(key, "")[:200] if isinstance(entry.get(key, ""), str) else ""
            for key in ("title", "artist", "album")}


def pick_sleeve(host, rng: random.Random, size: int, options: dict) -> tuple[Image.Image, dict]:
    """Retain a detailed square master, independent of a 64px wall's size."""
    size = max(512, min(1024, size))
    if options.get("image"):
        with Image.open(options["image"]) as source:
            img = source.convert("RGB")
        return prepare(img, size, unsharp_percent=0), _metadata(options)
    ctrl = getattr(host, "ctrl", None)
    entries = []
    if ctrl is not None and hasattr(ctrl, "journal_read"):
        entries = [e for e in ctrl.journal_read(300) if e.get("art_url")]
    showing = (getattr(ctrl, "now_showing", None) or {}).get("title") if ctrl is not None else None
    seen, pool = set(), []
    for e in entries:
        key = (_fold(e.get("artist")), _fold(e.get("album") or e.get("title")))
        if key in seen or e.get("title") == showing:
            continue
        seen.add(key)
        pool.append(e)
    rng.shuffle(pool)
    for e in pool[:6]:
        try:
            img = fetch_art(e["art_url"])
            return prepare(img, size, unsharp_percent=0), _metadata(e)
        except Exception as exc:
            print(f"[games] sleeve {e.get('title')}: {exc}", flush=True)
    raise RuntimeError("No sleeve in the journal yet. Play something first.")


def _size_of(host) -> int:
    ctrl = getattr(host, "ctrl", None)
    return int(getattr(getattr(ctrl, "wall", None), "width", 64) or 64)


@register
class Sliding(Game):
    name = "sliding"
    title = "Sliding puzzle"
    blurb = "A sleeve you have played, in blocks. Slide them back."
    min_players = 1
    max_players = 1

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        self.size = _size_of(self.host)
        self.sleeve, self.entry = pick_sleeve(self.host, rng, self.size, self.options)
        grid = self.options.get("grid", 3)
        if type(grid) is not int or grid not in (3, 4):
            raise ValueError("grid must be 3 or 4")
        self.n = grid
        self.tiles = list(range(self.n * self.n))          # tiles[pos] = which block; the last is the gap
        self.gap = self.n * self.n - 1
        # scramble by legal slides, never a parity trap; end away from solved
        for _ in range(60 * self.n):
            self._slide(rng.choice(self._moves()))
        if self.tiles == list(range(self.n * self.n)):
            self._slide(self._moves()[0])
        self.moves = 0
        self.undos = 0
        self.numbered = True
        self.history: list[tuple[list[int], int]] = []
        self.message = "Slide a highlighted tile into the empty space."
        self.faces = {}

    def _moves(self) -> list[int]:
        r, c = divmod(self.gap, self.n)
        out = []
        if r > 0: out.append(self.gap - self.n)
        if r < self.n - 1: out.append(self.gap + self.n)
        if c > 0: out.append(self.gap - 1)
        if c < self.n - 1: out.append(self.gap + 1)
        return out

    def _slide(self, pos: int) -> bool:
        if pos not in self._moves():
            return False
        self.tiles[self.gap], self.tiles[pos] = self.tiles[pos], self.tiles[self.gap]
        self.gap = pos
        return True

    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "the picture is back"}
        if not isinstance(move, dict):
            return {"error": "choose a tile beside the empty space"}
        if "numbers" in move:
            if type(move["numbers"]) is not bool:
                return {"error": "numbers must be on or off"}
            if self.numbered != move["numbers"]:
                self.numbered = move["numbers"]; self.changed()
            return {"numbers": self.numbered}
        if "undo" in move:
            if move["undo"] is not True or not self.history:
                return {"error": "no move to undo"}
            self.tiles, self.gap = self.history.pop()
            self.moves += 1; self.undos += 1
            self.message = "Last slide undone."
            self.changed()
            return {"undone": True, "moves": self.moves}
        if "tile" in move:
            pos = move["tile"]
            if type(pos) is not int or not 0 <= pos < self.n * self.n:
                return {"error": "choose a tile by its position"}
        else:
            direction = move.get("dir", move.get("direction", ""))
            if not isinstance(direction, str):
                return {"error": "up, down, left or right"}
            r, c = divmod(self.gap, self.n)
            pos = {"up": self.gap + self.n if r < self.n - 1 else -1,
                   "down": self.gap - self.n if r > 0 else -1,
                   "left": self.gap + 1 if c < self.n - 1 else -1,
                   "right": self.gap - 1 if c > 0 else -1}.get(direction.lower().strip(), -1)
        if pos not in self._moves():
            return {"error": "that tile is not beside the empty space"}
        before = (self.tiles.copy(), self.gap)
        self._slide(pos)
        self.history.append(before)
        del self.history[:-200]
        self.moves += 1
        if self.tiles == list(range(self.n * self.n)):
            self.finish(won=True, message=f"Back in {self.moves} {'move' if self.moves == 1 else 'moves'}.")
        else:
            self.message = f"{self.moves} move{'s' if self.moves != 1 else ''}."
            self.changed()
        return {"tiles": self.tiles.copy(), "moves": self.moves}

    def hear(self, text: str, player: str) -> dict | None:
        if not isinstance(text, str):
            return None
        t = text.lower().strip(" .!")
        if t in ("undo", "undo move", "take it back"):
            return self.apply({"undo": True}, player)
        t = {"slide up": "up", "move up": "up", "slide down": "down", "move down": "down",
             "slide left": "left", "move left": "left", "slide right": "right", "move right": "right"}.get(t, t)
        if t in ("up", "down", "left", "right"):
            return self.apply({"dir": t}, player)
        return None

    def state(self) -> dict:
        return {"n": self.n, "tiles": self.tiles.copy(), "gap": self.gap, "moves": self.moves,
                "legal": self._moves() if not self.over else [],
                "placed": sum(pos == tile for pos, tile in enumerate(self.tiles) if tile != self.n * self.n - 1),
                "numbers": self.numbered, "can_undo": bool(self.history) and not self.over, "undos": self.undos,
                "sleeve": _metadata(self.entry) if self.over else None}

    def voice_words(self) -> list[str]:
        return ["up", "down", "left", "right", "undo"]

    def frame_at(self, size: int, t: float):
        if size not in self.faces:
            self.faces[size] = self.sleeve.resize((size, size), Image.Resampling.LANCZOS)
            if len(self.faces) > 6:
                self.faces.pop(next(iter(self.faces)))
        source = self.faces[size]
        if self.over:
            return np.asarray(source, dtype=np.uint8).copy()
        canvas = blank(size)
        edges = [round(i * size / self.n) for i in range(self.n + 1)]
        seam = max(1, round(size * .006))
        legal = set(self._moves())
        for pos, tile in enumerate(self.tiles):
            r, c = divmod(pos, self.n)
            x, y = edges[c], edges[r]
            width, height = edges[c + 1] - x, edges[r + 1] - y
            if tile == self.n * self.n - 1:
                fill(canvas, x, y, width, height, (20, 25, 25))
                mark = max(2, round(size * .015))
                cx, cy = x + width // 2, y + height // 2
                line(canvas, (cx - mark, cy), (cx + mark, cy), (98, 117, 116), seam)
                line(canvas, (cx, cy - mark), (cx, cy + mark), (98, 117, 116), seam)
                continue
            tr, tc = divmod(tile, self.n)
            block = source.crop((edges[tc], edges[tr], edges[tc + 1], edges[tr + 1]))
            if block.size != (width, height):
                block = block.resize((width, height), Image.Resampling.LANCZOS)
            canvas[y:y + height, x:x + width] = np.asarray(block)
            rect(canvas, x, y, width, height, (11, 10, 9), seam)
            if pos in legal:
                rect(canvas, x + seam, y + seam, width - seam * 2, height - seam * 2, (197, 211, 172), max(1, round(size * .003)))
            if self.numbered:
                scale = max(1, round(size / 192))
                label = str(tile + 1)
                label_width = (len(label) * 6 - 1) * scale
                padding = max(1, round(size * .004))
                bx, by = x + seam + padding, y + seam + padding
                fill(canvas, bx, by, label_width + 2 * padding, 7 * scale + 2 * padding, (15, 18, 17))
                text(canvas, label, bx + padding, by + padding, (243, 241, 222), scale)
        return canvas

@register
class Reveal(Game):
    name = "reveal"
    title = "Cover reveal"
    blurb = "A sleeve sharpens over thirty seconds. First to name it wins."
    min_players = 1
    max_players = 8

    def setup(self):
        seconds = self.options.get("seconds", 30.0)
        if type(seconds) not in (int, float) or not math.isfinite(seconds) or not 1 <= seconds <= 300:
            raise ValueError("seconds must be a number from 1 to 300")
        self.seconds = float(seconds)
        rng = random.Random(self.options.get("seed"))
        self.size = _size_of(self.host)
        self.sleeve, self.entry = pick_sleeve(self.host, rng, self.size, self.options)
        self.answers = {_fold(self.entry.get(key, "")) for key in ("album", "artist", "title")} - {""}
        if not self.answers:
            raise RuntimeError("This sleeve needs an album, artist or song name.")
        self.t0 = time.monotonic()
        self._clock = time.monotonic
        self._park = ParkedClock()
        self.finished_elapsed: float | None = None
        self.guesses: list[tuple[str, str]] = []
        self.guess_count = 0
        self.blurred: dict[tuple[int, int], np.ndarray] = {}
        self.sources: dict[int, Image.Image] = {}
        self.message = "Name the album or the artist before the picture clears."

    def elapsed(self) -> float:
        if self.finished_elapsed is not None:
            return self.finished_elapsed
        # The countdown stands still while the game is parked off the wall:
        # the phone locks guessing then, and the phone's polls would
        # otherwise run the round out and record it as lost.
        now = self._park.read(self, self._clock())
        return min(self.seconds, max(0.0, now - self.t0))

    def finish(self, won=False, winner=None, message=None):
        if self.over:
            return
        self.finished_elapsed = self.elapsed()
        super().finish(won, winner, message)

    def apply(self, move: dict, player: str) -> dict:
        self.tick()
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(move, dict):
            return {"error": "enter an album, artist or song name"}
        word = move.get("guess", move.get("word", move.get("text", "")))
        if not isinstance(word, str):
            return {"error": "enter a name"}
        return self.guess(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        return self.guess(text, player) if isinstance(text, str) and text.strip() else None

    def guess(self, text: str, player: str) -> dict:
        self.tick()  # The deadline wins even if no render or status poll ran.
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 120:
            return {"error": "enter a name up to 120 characters"}
        text = text.strip()
        guess = _fold(text)
        if not guess:
            return {"error": "say a name"}
        if any(_fold(old) == guess and who == player for old, who in self.guesses):
            return {"error": "you already tried that name"}
        self.guesses.append((text, player)); self.guess_count += 1
        del self.guesses[:-80]
        # Only a complete normalized name wins. In particular, “not Frank
        # Ocean”, “Ocean”, and arbitrary text containing a title cannot win.
        hit = guess in self.answers
        if hit:
            seconds = round(self.elapsed(), 1)
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"Recognised in {seconds:g} seconds.")
            return {"hit": True, "seconds": seconds}
        self.message = "Keep looking. The picture is getting clearer."
        self.changed()
        return {"hit": False}

    def tick(self):
        if not self.over and self.elapsed() >= self.seconds:
            self.finish(won=False, message="The picture is revealed.")

    def public(self) -> dict:
        # Game.public builds its outer flags before calling state(). Tick first
        # so the first deadline response has matching flags and answer fields.
        self.tick()
        return super().public()

    def state(self) -> dict:
        self.tick()
        elapsed = self.elapsed()
        fraction = min(1.0, elapsed / self.seconds)
        return {"elapsed": round(elapsed, 1), "seconds": self.seconds,
                "remaining": round(max(0, self.seconds - elapsed), 1), "progress": fraction,
                "frame_step": 20 if self.over else min(19, int(fraction * 20)),
                "guesses": [{"text": text, "who": who} for text, who in self.guesses[-12:]],
                "guess_count": self.guess_count,
                "answer": _metadata(self.entry) if self.over else None}

    def voice_words(self) -> list[str]:
        return []

    def frame_at(self, size: int, t: float):
        self.tick()
        if size not in self.sources:
            self.sources[size] = self.sleeve.resize((size, size), Image.Resampling.LANCZOS)
            if len(self.sources) > 6:
                self.sources.pop(next(iter(self.sources)))
        source = self.sources[size]
        if self.over:
            return np.asarray(source, dtype=np.uint8).copy()
        fraction = self.elapsed() / self.seconds
        step = min(19, int(fraction * 20))
        key = (size, step)
        if key not in self.blurred:
            radius = (1.0 - step / 20.0) ** 1.6 * size / 5.0
            image = source.filter(ImageFilter.GaussianBlur(radius)) if radius > 0.15 else source
            self.blurred[key] = np.asarray(image, dtype=np.uint8)
            # Three sizes and nearby reveal steps, rather than retaining every
            # 512px frame for the whole round on the wall's small computer.
            while len(self.blurred) > 9:
                self.blurred.pop(next(iter(self.blurred)))
        frame = self.blurred[key].copy()
        rail = max(1, round(size * .012))
        progress(frame, 0, size - rail, size, rail, fraction, (244, 219, 164), (29, 29, 28), head=None)
        return frame
