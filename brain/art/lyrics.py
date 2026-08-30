"""Lyrics over the sleeve, in time with the song.

Source: LRCLIB (lrclib.net), the open synced-lyrics archive. One GET keyed
by track, artist, album and duration; the answer's syncedLyrics is LRC text,
"[mm:ss.xx] line" per line. No auth, no key, and misses are common enough
that having none is a first-class state here, never an error.

Display: the current line only, wrapped in the wall's own font, lettered
over the sleeve dimmed to a quarter of itself. Words arrive one at a time
across the early part of the line's window, each with a two-frame brightness
ramp so it lands rather than teleports; the whole line then stands until the
next one takes over. LRC gives line times, not word times, so word timing is
an even spread, which is a guess, and an honest one: it is how people read.
"""
import re
import threading

import numpy as np
from PIL import Image

from .pixelfont import FONT, draw_text, normalize, text_width
from .text_modes import wrap_text

_STAMP = re.compile(r"\[(\d+):(\d+(?:\.\d+)?)\]")


def parse_lrc(text: str) -> list[tuple[float, str]]:
    """[(seconds, line)], sorted. A line may carry several stamps."""
    out = []
    for raw in text.splitlines():
        stamps = _STAMP.findall(raw)
        if not stamps:
            continue
        words = _STAMP.sub("", raw).strip()
        for m, s in stamps:
            out.append((int(m) * 60 + float(s), words))
    out.sort(key=lambda p: p[0])
    return out


class LyricSheet:
    """One track's synced lines, and where we are in them."""

    def __init__(self, lines: list[tuple[float, str]]):
        self.lines = lines

    def at(self, t: float):
        """(line_text, starts, ends) for time t; text may be "" between
        lines that LRC marks as instrumental gaps."""
        lines = self.lines
        if not lines or t < lines[0][0]:
            return "", 0.0, lines[0][0] if lines else 0.0
        lo, hi = 0, len(lines) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if lines[mid][0] <= t:
                lo = mid
            else:
                hi = mid - 1
        t0 = lines[lo][0]
        t1 = lines[lo + 1][0] if lo + 1 < len(lines) else t0 + 6.0
        return lines[lo][1], t0, t1


def fetch_sheet(artist: str, title: str, album: str,
                duration_s: float | None) -> LyricSheet | None:
    """One exact lookup, then one search. None means none exist, which the
    caller shows as the plain sleeve rather than as a failure."""
    import requests
    base = "https://lrclib.net/api"
    try:
        params = {"artist_name": artist, "track_name": title}
        if album:
            params["album_name"] = album
        if duration_s:
            params["duration"] = int(duration_s)
        resp = requests.get(base + "/get", params=params, timeout=10)
        data = resp.json() if resp.status_code == 200 else None
        if not (data and data.get("syncedLyrics")):
            resp = requests.get(base + "/search",
                                params={"artist_name": artist,
                                        "track_name": title},
                                timeout=10)
            hits = resp.json() if resp.status_code == 200 else []
            data = next((h for h in hits if h.get("syncedLyrics")), None)
        if not (data and data.get("syncedLyrics")):
            return None
        lines = parse_lrc(data["syncedLyrics"])
        return LyricSheet(lines) if lines else None
    except Exception:
        return None


class LyricBook:
    """The fetch, made non-blocking: ask() starts a thread once per track and
    the render loop reads whatever state exists this frame."""

    def __init__(self):
        self.track = None
        self.sheet = None
        self.state = "idle"          # idle | loading | done | none

    def ask(self, track_id, artist, title, album, duration_s):
        if track_id == self.track:
            return
        self.track = track_id
        self.sheet = None
        self.state = "loading"

        def work():
            sheet = fetch_sheet(artist or "", title or "", album or "",
                                duration_s)
            # a slow answer for a track we already left is nobody's news
            if self.track == track_id:
                self.sheet = sheet
                self.state = "done" if sheet else "none"

        threading.Thread(target=work, daemon=True).start()


class LyricCanvas:
    """Renders one track's lines over its sleeve."""

    DIM = 0.26            # how much of the sleeve survives under the words
    RAMP = 0.16           # seconds a new word takes to reach full ink

    def __init__(self, size: int, art: Image.Image, sheet: LyricSheet,
                 color: str = "#f4f1ea"):
        self.size = size
        self.sheet = sheet
        base = np.asarray(
            art.convert("RGB").resize((size, size), Image.LANCZOS),
            dtype=np.float32) * self.DIM
        self.base = base
        s = color.lstrip("#")
        self.ink = tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))
        self._wrapped: dict[str, list[str]] = {}

    def _rows(self, text: str) -> list[str]:
        rows = self._wrapped.get(text)
        if rows is None:
            # Letter what the font can letter. K-pop and half the world mix
            # scripts mid-line; the ASCII fragments keep their timing and the
            # rest steps aside, which beats rows of fallback boxes. A line
            # with nothing letterable shows the sleeve alone for its bar.
            kept = "".join(
                ch for ch in normalize(text)
                if ch in FONT or ch == " ")
            kept = " ".join(kept.split())
            rows = wrap_text(kept, self.size - 6, 1)[:6] if kept else []
            self._wrapped[text] = rows
        return rows

    def frame_at(self, t: float) -> Image.Image:
        canvas = self.base.copy()
        text, t0, t1 = self.sheet.at(t)
        if text:
            rows = self._rows(text)
            tokens = [w for row in rows for w in row.split()]
            n = max(1, len(tokens))
            # words spread across the front of the line's window: readable
            # long before the next line, and never slower than the song
            span = min(2.4, max(0.6, (t1 - t0) * 0.55))
            step = span / n

            line_h = 9
            block_h = len(rows) * line_h - 2
            y = (self.size - block_h) // 2
            shown = 0
            arr = canvas
            for row in rows:
                x = (self.size - text_width(row, 1)) // 2
                for word in row.split():
                    born = t0 + shown * step
                    if t >= born:
                        k = min(1.0, (t - born) / self.RAMP)
                        ink = tuple(int(c * (0.25 + 0.75 * k)) for c in self.ink)
                        u8 = np.zeros((self.size, self.size, 3), dtype=np.uint8)
                        # the shadow: paint the offset copy white to get its
                        # footprint (black on zeros has none), then darken
                        draw_text(u8, word, x + 1, y + 1, (255, 255, 255), 1)
                        mask = u8.sum(axis=2) > 0
                        arr[mask] *= 0.25
                        u8[:] = 0
                        draw_text(u8, word, x, y, ink, 1)
                        mask = u8.sum(axis=2) > 0
                        arr[mask] = u8[mask]
                    shown += 1
                    x += text_width(word, 1) + 6
                y += line_h
        return Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), "RGB")
