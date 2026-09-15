"""Two games on a sleeve from the wall's own history.

Sliding picture puzzle: a sleeve the wall has worn, cut into a 3x3 (or
4x4) of blocks with one missing, scrambled by a walk of legal slides so
it can always be put back, and slid back by the phone (tap a block next
to the gap) or by voice ("up" slides the block below the gap up into it,
and so on). The wall shows the blocks; the count of moves at 192.

Cover reveal: a sleeve starts as a blur and sharpens over thirty seconds;
the first to name the album or the artist wins, by voice or by typing.
The blur is the sleeve at the wall's size through a Gaussian whose radius
falls with time, drawn a few times a second. After thirty seconds it is
sharp and the name shows.

Both take their sleeves from the journal, the last few hundred songs,
skipping the one that is on; a test can hand in an image with
{"image": path}. Options: {"grid": 3 | 4}, {"seed": n}, {"seconds": s}.
"""
from __future__ import annotations

import random
import re
import time

import numpy as np
from PIL import Image, ImageFilter

from . import Game, register
from .board import (BLACK, DIM, FAINT, INK, SLATE, WHITE, banner, blank, ease_out, fill, header, mix, progress,
                    scale_for, shade, text, text_centred, fit_text)
from ..art.fetch import fetch_art
from ..art.pipeline import prepare


def _fold(s: str) -> str:
    s = re.sub(r"\(.*?\)|\[.*?\]", " ", (s or "").lower())
    s = re.sub(r"\b(feat|ft|featuring)\b.*$", " ", s)
    s = re.sub(r"[^a-z0-9 ]", " ", s)
    s = re.sub(r"^(the|a|an) ", "", " ".join(s.split()))
    return s.strip()


def pick_sleeve(host, rng: random.Random, size: int, options: dict) -> tuple[Image.Image, dict]:
    """A prepared sleeve at the wall's size and the journal entry it came
    from (title, artist, album)."""
    if options.get("image"):
        img = Image.open(options["image"]).convert("RGB")
        return prepare(img, size, unsharp_percent=0), {"title": options.get("title", ""),
                                                        "artist": options.get("artist", ""),
                                                        "album": options.get("album", "")}
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
            return prepare(img, size, unsharp_percent=0), e
        except Exception as exc:
            print(f"[games] sleeve {e.get('title')}: {exc}", flush=True)
    raise RuntimeError("no sleeve in the journal yet; play something first")


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
        self.n = 4 if int(self.options.get("grid", 3)) == 4 else 3
        self.tiles = list(range(self.n * self.n))          # tiles[pos] = which block; the last is the gap
        self.gap = self.n * self.n - 1
        # scramble by legal slides, never a parity trap; end away from solved
        for _ in range(60 * self.n):
            self._slide(rng.choice(self._moves()))
        if self.tiles == list(range(self.n * self.n)):
            self._slide(self._moves()[0])
        self.moves = 0
        self.message = "Slide the blocks."
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
        if "tile" in move:
            try:
                pos = int(move["tile"])
            except (TypeError, ValueError):
                return {"error": "a block, by its place"}
        else:
            d = str(move.get("dir") or move.get("direction") or "").lower()
            r, c = divmod(self.gap, self.n)
            pos = {"up": self.gap + self.n if r < self.n - 1 else -1,      # the block below moves up
                   "down": self.gap - self.n if r > 0 else -1,
                   "left": self.gap + 1 if c < self.n - 1 else -1,
                   "right": self.gap - 1 if c > 0 else -1}.get(d, -1)
            if pos < 0:
                return {"error": "up, down, left or right"}
        if not self._slide(pos):
            return {"error": "that block is not next to the gap"}
        self.moves += 1
        if self.tiles == list(range(self.n * self.n)):
            self.finish(won=True, message=f"Back in {self.moves}.")
        else:
            self.message = f"{self.moves} moves."
            self.changed()
        return {"tiles": self.tiles, "moves": self.moves}

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip(" .!")
        t = {"slide up": "up", "move up": "up", "slide down": "down", "move down": "down",
             "slide left": "left", "move left": "left", "slide right": "right", "move right": "right"}.get(t, t)
        if t in ("up", "down", "left", "right"):
            return self.apply({"dir": t}, player)
        return None

    def state(self) -> dict:
        return {"n": self.n, "tiles": self.tiles, "gap": self.gap, "moves": self.moves,
                "sleeve": {"title": self.entry.get("title", ""), "artist": self.entry.get("artist", "")}
                if self.over else None}

    def voice_words(self) -> list[str]:
        return ["up", "down", "left", "right"]

    def frame_at(self, size: int, t: float):
        if size not in self.faces:
            src = self.sleeve if self.sleeve.size[0] == size else self.sleeve.resize((size, size), Image.LANCZOS)
            self.faces[size] = np.asarray(src, dtype=np.uint8)
        src = self.faces[size]
        c = blank(size)
        n = self.n
        cell = size // n
        off = (size - cell * n) // 2
        seam = 1 if size <= 96 else 2
        for pos, tilei in enumerate(self.tiles):
            pr, pc = divmod(pos, n)
            y, x = off + pr * cell, off + pc * cell
            if tilei == n * n - 1 and not self.over:
                fill(c, x, y, cell, cell, SLATE)
                fill(c, x + cell // 2 - seam, y + cell // 2 - seam, 2 * seam, 2 * seam, FAINT)
                continue
            tr, tc = divmod(tilei, n)
            block = src[tr * cell:(tr + 1) * cell, tc * cell:(tc + 1) * cell]
            c[y:y + cell, x:x + cell] = block
            if not self.over:
                shade(c, x, y, cell, seam, 0.45)
                shade(c, x, y, seam, cell, 0.45)
                shade(c, x, y + cell - seam, cell, seam, 0.75)
                shade(c, x + cell - seam, y, seam, cell, 0.75)
        if self.over and self.age() < 0.6:
            # a wash of light as the picture comes back whole
            a = 1.0 - ease_out(self.age() / 0.6)
            c[...] = np.clip(c.astype(np.float32) + 160 * a, 0, 255).astype(np.uint8)
        return c

@register
class Reveal(Game):
    name = "reveal"
    title = "Cover reveal"
    blurb = "A sleeve sharpens over thirty seconds. First to name it wins."
    min_players = 1
    max_players = 8

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        self.size = _size_of(self.host)
        self.sleeve, self.entry = pick_sleeve(self.host, rng, self.size, self.options)
        self.seconds = float(self.options.get("seconds", 30.0))
        self.t0 = time.monotonic()
        self._clock = time.monotonic
        self.answers = {_fold(self.entry.get("album", "")), _fold(self.entry.get("artist", "")),
                        _fold(self.entry.get("title", ""))} - {""}
        self.guesses: list[tuple[str, str]] = []
        self.blurred: dict[tuple[int, int], np.ndarray] = {}
        self.message = "Name the album or the artist."

    def elapsed(self) -> float:
        return self._clock() - self.t0

    def apply(self, move: dict, player: str) -> dict:
        word = str(move.get("guess") or move.get("word") or move.get("text") or "").strip()
        return self.guess(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        t = text.strip()
        if len(t) < 2:
            return None
        return self.guess(t, player)

    def guess(self, text: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        g = _fold(text)
        if not g:
            return {"error": "say a name"}
        self.guesses.append((text, player))
        hit = any(g == a or (len(g) > 3 and (g in a or a in g)) for a in self.answers)
        if hit:
            secs = round(self.elapsed(), 1)
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"{player} at {secs} s: {self.entry.get('artist', '')} — {self.entry.get('album') or self.entry.get('title', '')}")
            return {"hit": True, "seconds": secs}
        self.message = f"Not {text}."
        self.changed()
        return {"hit": False}

    def tick(self):
        if not self.over and self.elapsed() >= self.seconds:
            self.finish(won=False, message=f"{self.entry.get('artist', '')} — {self.entry.get('album') or self.entry.get('title', '')}")

    def state(self) -> dict:
        self.tick()
        return {"elapsed": round(self.elapsed(), 1), "seconds": self.seconds,
                "guesses": [{"text": g, "who": p} for g, p in self.guesses],
                "answer": {"title": self.entry.get("title", ""), "artist": self.entry.get("artist", ""),
                           "album": self.entry.get("album", "")} if self.over else None}

    def voice_words(self) -> list[str]:
        return []

    def frame_at(self, size: int, t: float):
        self.tick()
        src = self.sleeve if self.sleeve.size[0] == size else self.sleeve.resize((size, size), Image.LANCZOS)
        if self.over:
            f = np.asarray(src, dtype=np.uint8).copy()
            who = self.winner or (self.players[0] if self.won else "")
            label = (f"{self.entry.get('artist', '')} — {self.entry.get('album') or self.entry.get('title', '')}"
                     if size > 96 else (self.entry.get("album") or self.entry.get("title", "")))
            banner(f, size, label, INK, mix((40, 120, 70), BLACK, 0.45) if self.won else (40, 30, 30))
            return f
        frac = min(1.0, self.elapsed() / self.seconds)
        step = int(frac * 20)
        key = (size, step)
        if key not in self.blurred:
            radius = (1.0 - step / 20.0) ** 1.6 * size / 5.0
            img = src.filter(ImageFilter.GaussianBlur(radius)) if radius > 0.15 else src
            self.blurred[key] = np.asarray(img, dtype=np.uint8)
        f = self.blurred[key].copy()
        s = scale_for(size)
        progress(f, 0, size - s, size, s, frac, WHITE, (20, 20, 24), head=None)
        return f

