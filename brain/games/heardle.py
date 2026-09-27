"""Heardle on the wall.

A song from the wall's own history, played from its iTunes preview by the
phone: one second first, then two, four, seven, eleven and sixteen as
guesses miss or are skipped. Name it, by voice or typed, in six. The wall
draws the six bars, filling as they are unlocked, a needle running while
the phone plays, and on the reveal the sleeve with the name running under
it. Two or more players take turns guessing.

The song comes from the journal (a title and artist the wall has shown)
or from the shelf when there is one; the preview from iTunes, the same
lookup the teacher uses (brain/nowplaying/teach.py). The phone plays the
preview itself, from the URL in the state, for the seconds allowed. A
test can hand in {"title", "artist", "preview"}. Options: {"seed": n}.
"""
from __future__ import annotations

import random
import math
import unicodedata
from urllib.parse import urlparse
import re
import time

from . import Game, register
from .board import arc, blank, disc, rounded, text_centred, fit_text
from ..art.fetch import fetch_art
from ..art.pipeline import prepare
from .pictures import _fold

STEPS = [1, 2, 4, 7, 11, 16]
_SKIP = re.compile(r"^(skip|pass|next|more)[.!?]*$")


def answer_key(text):
    if not isinstance(text, str):
        return ""
    value = unicodedata.normalize("NFKD", text.casefold())
    value = "".join(c for c in value if not unicodedata.combining(c))
    value = value.replace("’", "").replace("'", "")
    return " ".join("".join(c if c.isalnum() else " " for c in value).split())


def pick_song(host, rng: random.Random, options: dict) -> dict:
    if options.get("title") and options.get("preview"):
        return {"title": options["title"], "artist": options.get("artist", ""), "album": options.get("album", ""),
                "preview": options["preview"], "art_url": options.get("art_url"), "duration_ms": None}
    from ..nowplaying.teach import itunes_preview
    ctrl = getattr(host, "ctrl", None)
    entries = []
    if ctrl is not None and hasattr(ctrl, "journal_read"):
        entries = [e for e in ctrl.journal_read(300) if e.get("title") and e.get("artist") and e.get("kind") != "show"]
    showing = (getattr(ctrl, "now_showing", None) or {}).get("title") if ctrl is not None else None
    seen, pool = set(), []
    for e in entries:
        key = (_fold(e.get("title")), _fold(e.get("artist")))
        if key in seen or e.get("title") == showing:
            continue
        seen.add(key)
        pool.append(e)
    rng.shuffle(pool)
    for e in pool[:8]:
        found = itunes_preview(e["title"], e["artist"])
        if found and found.get("preview"):
            return {"title": e["title"], "artist": e["artist"], "album": e.get("album", ""),
                    "preview": found["preview"], "art_url": found.get("art_url") or e.get("art_url"),
                    "duration_ms": found.get("duration_ms")}
    raise RuntimeError("no song with a preview in the journal yet; play something first")


@register
class Heardle(Game):
    name = "heardle"
    title = "Heardle"
    blurb = "A song you have played, a second at a time. Name it in six."
    min_players = 1
    max_players = 6

    def setup(self):
        self.song = pick_song(self.host, random.Random(self.options.get("seed")), self.options)
        if not isinstance(self.song.get("title"), str) or not self.song["title"].strip():
            raise ValueError("a song title is required")
        preview = self.song.get("preview")
        if not isinstance(preview, str) or len(preview) > 4096 or urlparse(preview).scheme not in ("https", "http") or not urlparse(preview).netloc:
            raise ValueError("a valid audio preview URL is required")
        self.answers = {answer_key(self.song["title"])} - {""}
        self.step, self.turn, self.play_count = 0, 0, 0
        self.tries: list[tuple[str, str, bool]] = []
        self.playing_until = None
        self._clock = time.monotonic
        self.sleeve = None
        self._sleeves = {}
        # Fetch once during setup, never while drawing under the render lock.
        try:
            image = self.options.get("image") or self.options.get("art_path")
            if image:
                from PIL import Image
                with Image.open(image) as source:
                    self.sleeve = prepare(source.convert("RGB"), 512, unsharp_percent=0)
            elif self.song.get("art_url"):
                self.sleeve = prepare(fetch_art(self.song["art_url"]), 512, unsharp_percent=0)
        except Exception as exc:
            print(f"[games] heardle sleeve: {exc}", flush=True)
        self.message = "One second. Name that song."

    @property
    def seconds(self):
        return STEPS[min(self.step, len(STEPS) - 1)]

    def _guard(self, player):
        if self.over:
            return {"error": "the game is over"}
        if player not in self.players:
            return {"error": "unknown player"}
        if player != self.players[self.turn]:
            return {"error": f"it is {self.players[self.turn]}'s turn"}
        return None

    def apply(self, move, player):
        if error := self._guard(player):
            return error
        if "step" in move and (type(move["step"]) is not int or move["step"] != self.step):
            return {"error": "the listening step has changed"}
        if "played" in move:
            if type(move["played"]) is not bool:
                return {"error": "played must be true or false"}
            position = move.get("position", 0)
            if type(position) not in (int, float) or not math.isfinite(position) or not 0 <= position <= self.seconds:
                return {"error": "invalid playback position"}
            self.playing_until = self._clock() + self.seconds - position if move["played"] else None
            if move["played"]:
                self.play_count += 1
            self.changed()
            return {"seconds": self.seconds, "playing": move["played"]}
        if "skip" in move:
            if move["skip"] is not True:
                return {"error": "skip must be true"}
            return self.skip(player)
        text = next((move[k] for k in ("guess", "word", "text") if k in move), "")
        return self.guess(text, player)

    def hear(self, text, player):
        if not isinstance(text, str) or not text.strip():
            return None
        if _SKIP.fullmatch(text.strip().lower()):
            return self.skip(player)
        return self.guess(text, player)

    def _miss(self, text, player, skipped):
        self.playing_until = None
        self.tries.append((text, player, skipped))
        self.turn = (self.turn + 1) % len(self.players)
        if len(self.tries) >= len(STEPS):
            self.finish(won=False, message=f"{self.song['artist']} — {self.song['title']}")
        else:
            self.step = len(self.tries)
            self.message = f"{self.seconds} seconds now."
            self.changed()

    def skip(self, player):
        if error := self._guard(player):
            return error
        self._miss("", player, True)
        return {"skipped": True, "seconds": self.seconds if not self.over else 0}

    def guess(self, text, player):
        if error := self._guard(player):
            return error
        if not isinstance(text, str) or not 1 <= len(text.strip()) <= 120 or not answer_key(text):
            return {"error": "enter a song title, up to 120 characters"}
        text = text.strip()
        if answer_key(text) in self.answers:
            self.playing_until = None
            self.tries.append((text, player, False))
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"{self.song['artist']} — {self.song['title']}, in {len(self.tries)}.")
            return {"hit": True, "tries": len(self.tries)}
        self._miss(text, player, False)
        return {"hit": False, "seconds": self.seconds if not self.over else 0}

    def state(self):
        playing = bool(not self.over and self.playing_until and self._clock() < self.playing_until)
        position = max(0.0, self.seconds - (self.playing_until - self._clock())) if playing else 0.0
        return {"seconds": self.seconds, "step": self.step, "steps": list(STEPS), "preview": self.song["preview"],
                "tries": [{"text": t, "who": p, "skipped": s, "hit": bool(self.won and i == len(self.tries) - 1)}
                          for i, (t, p, s) in enumerate(self.tries)],
                "turn": self.players[self.turn], "playing": playing, "playback_position": round(position, 2),
                "frame_step": int(position * 2) + 1 if playing else 0,
                "answer": {k: self.song.get(k, "") for k in ("title", "artist", "album", "art_url")} if self.over else None}

    def voice_words(self):
        return ["skip"]

    def _sleeve(self, size):
        if self.sleeve is None:
            return None
        if size not in self._sleeves:
            from PIL import Image
            self._sleeves[size] = self.sleeve.resize((size, size), Image.Resampling.LANCZOS)
        return self._sleeves[size]

    def frame_at(self, size, t):
        import numpy as np
        c = blank(size)
        c[:] = (18, 22, 26)
        gold, cream, muted = (220, 185, 70), (245, 228, 190), (104, 114, 120)
        if self.over and self._sleeve(size) is not None:
            return np.asarray(self._sleeve(size), dtype=np.uint8).copy()
        s = max(1, size // 128)
        big = size >= 128
        cx, cy, radius = size // 2, round(size * .43), round(size * .29)
        # A quiet record face and an honest, finite listening window.
        disc(c, cx, cy, radius, (35, 43, 48))
        for f in (.96, .83, .70, .57):
            arc(c, cx, cy, round(radius * f), 0, 360, (54, 62, 66), max(1, size // 256))
        disc(c, cx, cy, radius * .39, gold)
        disc(c, cx, cy, max(1, size * .014), (18, 22, 26))
        state = self.state()
        if state["playing"]:
            arc(c, cx, cy, radius + max(2, size // 64), 0,
                360 * state["playback_position"] / self.seconds, cream, max(1, size // 128))
        text_centred(c, "HEARDLE" if not self.over else "FOUND" if self.won else "THE REVEAL", cx, round(size * .045), cream, s)
        if self.over:
            # Missing artwork still has an intentional, complete result face.
            label = self.song["title"]
            text_centred(c, fit_text(label.upper(), size - 8, s), cx, round(size * .81), cream, s)
            return c
        text_centred(c, f"{self.seconds}s", cx, round(size * .61), cream, max(1, size // 96))
        gap = max(2, round(size * .015))
        left = round(size * .075)
        usable = size - left * 2
        for i, seconds in enumerate(STEPS):
            x0 = left + round(i * usable / 6)
            x1 = left + round((i + 1) * usable / 6) - gap
            colour = gold if i == self.step else (89, 93, 96) if i < self.step else (44, 52, 57)
            rounded(c, x0, round(size * .79), x1 - x0, max(3, round(size * .045)), colour, max(1, size // 128))
            if big:
                text_centred(c, str(seconds), (x0 + x1) // 2, round(size * .865), cream if i == self.step else muted, s)
        if not big:
            text_centred(c, f"{len(self.tries) + 1}/6", cx, min(size - 8, round(size * .9)), muted, 1)
        return c
