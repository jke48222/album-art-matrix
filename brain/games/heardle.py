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
import re
import time

from . import Game, register
from .board import (BLACK, DIM, FAINT, GREEN, INK, RED, SLATE2, WHITE, YELLOW, banner, blank, disc, fill, glow,
                    header, mix, rounded, scale_for, text, text_centred, fit_text)
from ..art.fetch import fetch_art
from ..art.pipeline import prepare
from .pictures import _fold

STEPS = [1, 2, 4, 7, 11, 16]
_SKIP = re.compile(r"^(skip|pass|next|more)[.!?]*$")


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
        rng = random.Random(self.options.get("seed"))
        self.song = pick_song(self.host, rng, self.options)
        self.answers = {_fold(self.song["title"])} - {""}
        self.step = 0                        # index into STEPS: how much is unlocked
        self.tries: list[tuple[str, str, bool]] = []   # (text, who, skipped)
        self.turn = 0
        self.playing_until: float | None = None
        self.play_count = 0
        self.sleeve = None
        self._clock = time.monotonic
        self.message = f"{STEPS[0]} second. Say the song."

    @property
    def seconds(self) -> int:
        return STEPS[min(self.step, len(STEPS) - 1)]

    def apply(self, move: dict, player: str) -> dict:
        if move.get("skip"):
            return self.skip(player)
        if move.get("played") is not None:
            # the phone says it is playing the clip now, for the wall's needle
            self.playing_until = self._clock() + float(self.seconds)
            self.play_count += 1
            self.changed()
            return {"seconds": self.seconds}
        text = str(move.get("guess") or move.get("word") or move.get("text") or "").strip()
        return self.guess(text, player)

    def hear(self, text: str, player: str) -> dict | None:
        t = text.strip()
        if _SKIP.match(t.lower()):
            return self.skip(player)
        if len(t) < 2:
            return None
        return self.guess(t, player)

    def _miss(self, text: str, player: str, skipped: bool):
        self.tries.append((text, player, skipped))
        self.turn = (self.turn + 1) % len(self.players)
        if len(self.tries) >= len(STEPS):
            self.finish(won=False, message=f"{self.song['artist']} — {self.song['title']}")
        else:
            self.step = len(self.tries)
            self.message = f"{self.seconds} seconds now."
            self.changed()

    def skip(self, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        self._miss("", player, True)
        return {"skipped": True, "seconds": self.seconds if not self.over else 0}

    def guess(self, text: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        g = _fold(text)
        if not g:
            return {"error": "say the song"}
        hit = any(g == a or (len(g) > 3 and (g in a or a in g)) for a in self.answers)
        if hit:
            n = len(self.tries) + 1
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"{self.song['artist']} — {self.song['title']}, in {n}.")
            return {"hit": True, "tries": n}
        self._miss(text, player, False)
        return {"hit": False, "seconds": self.seconds if not self.over else 0}

    def state(self) -> dict:
        return {"seconds": self.seconds, "step": self.step, "steps": STEPS, "preview": self.song["preview"],
                "tries": [{"text": t, "who": p, "skipped": s} for t, p, s in self.tries],
                "turn": self.players[self.turn], "playing": bool(self.playing_until and self._clock() < self.playing_until),
                "answer": {"title": self.song["title"], "artist": self.song["artist"], "album": self.song.get("album", ""),
                           "art_url": self.song.get("art_url")} if self.over else None}

    def voice_words(self) -> list[str]:
        return ["skip"]

    def _sleeve(self, size: int):
        if self.sleeve is None or self.sleeve.size[0] != size:
            url = self.song.get("art_url")
            if not url:
                return None
            try:
                self.sleeve = prepare(fetch_art(url), size, unsharp_percent=0)
            except Exception as exc:
                print(f"[games] heardle sleeve: {exc}", flush=True)
                self.song["art_url"] = None
                return None
        return self.sleeve

    def frame_at(self, size: int, t: float):
        s = scale_for(size)
        big = size > 96
        if self.over:
            sleeve = self._sleeve(size)
            if sleeve is not None:
                import numpy as np
                f = np.asarray(sleeve, dtype=np.uint8).copy()
                banner(f, size, f"{self.song['artist']} — {self.song['title']}" if big else self.song["title"],
                       INK, mix(GREEN, BLACK, 0.55) if self.won else (40, 30, 30))
                return f
            c = blank(size)
            text_centred(c, fit_text(self.song["title"].upper(), size - 4, s), size // 2, size // 2 - 8 * s, INK, s)
            text_centred(c, fit_text(self.song["artist"], size - 4, s), size // 2, size // 2 + 2 * s, DIM, s)
            return c
        c = blank(size)
        total = sum(STEPS)
        x = 2 * s
        width = size - 4 * s
        y = size // 2 - 4 * s
        h = 8 * s
        playing = bool(self.playing_until and self._clock() < self.playing_until)
        for i, sec in enumerate(STEPS):
            w = max(2 * s, int(width * sec / total) - s)
            if i < len(self.tries):
                colour = mix(SLATE2, WHITE, 0.15) if self.tries[i][2] else mix(RED, BLACK, 0.35)
            elif i <= self.step:
                colour = YELLOW
            else:
                colour = FAINT
            rounded(c, x, y, w, h, colour, 1 if not big else 3)
            if big and i <= self.step and i >= len(self.tries):
                fill(c, x + 3, y, w - 6, 1, mix(colour, WHITE, 0.2))
            x += w + s
        # the needle while the phone plays, with a little light around it
        if playing:
            frac = 1.0 - (self.playing_until - self._clock()) / max(1.0, float(self.seconds))
            px = 2 * s + int((size - 4 * s) * frac * self.seconds / total)
            glow(c, px, y + h / 2, 6 * s, WHITE, 0.35)
            fill(c, px, y - 2 * s, s, h + 4 * s, WHITE)
        text_centred(c, f"{self.seconds}s", size // 2, y + h + 4 * s, INK, s)
        # the six tries as dots under
        dx = size // 2 - 6 * 3 * s // 2 + s
        for i in range(len(STEPS)):
            colour = (mix(RED, BLACK, 0.3) if not self.tries[i][2] else DIM) if i < len(self.tries) else FAINT
            disc(c, dx + i * 3 * s + s, y + h + 14 * s, 0.9 * s, colour)
        if big and self.tries:
            last = self.tries[-1]
            text_centred(c, fit_text("skipped" if last[2] else f"not {last[0]}", size - 12, 1), size // 2, size - 12, DIM, 1)
        header(c, size, "HEARDLE", f"try {len(self.tries) + 1} of 6", s, accent=YELLOW)
        return c

