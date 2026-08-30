"""Lyrics over the sleeve, in time with the song.

Source: LRCLIB (lrclib.net), the open synced-lyrics archive. One GET keyed
by track, artist, album and duration; the answer's syncedLyrics is LRC text,
"[mm:ss.xx] line" per line. No auth, no key, and misses are common enough
that having none is a first-class state here, never an error.

Display: the brat look. A flat field in the album's loudest voice, the
line in lowercase filling the panel from the left, black or white by
whatever the field needs, words popping in one at a time. Big where the
line is short, smaller only when it must be. Between lines the field just
holds, which is the confidence the whole aesthetic runs on. LRC gives line
times, not word times, so word timing is an even spread, which is a guess,
and an honest one: it is how people read.
"""
import colorsys
import re
import threading

import numpy as np
from PIL import Image

from .pixelfont import cell, draw_text, normalize, text_width
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
    """One track's lines, on the flat loud field."""

    RAMP = 0.12           # seconds a new word takes to land

    def __init__(self, size: int, art, sheet: LyricSheet,
                 color: str = "#8ace00"):
        self.size = size
        self.sheet = sheet
        # the field: the given colour pushed toward its loudest self
        c = color.lstrip("#")
        r, g, b = (int(c[i:i + 2], 16) / 255 for i in (0, 2, 4))
        h, s_, v = colorsys.rgb_to_hsv(r, g, b)
        r, g, b = colorsys.hsv_to_rgb(h, min(1.0, s_ * 1.5 + 0.12),
                                      min(1.0, v * 1.25 + 0.18))
        self.bg = (int(r * 255), int(g * 255), int(b * 255))
        lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        self.ink = (12, 12, 10) if lum > 0.45 else (244, 241, 234)
        self.base = np.broadcast_to(
            np.array(self.bg, dtype=np.uint8), (size, size, 3)).copy()
        self._laid: dict[str, tuple[list[str], int]] = {}

    def _layout(self, text: str) -> tuple[list[str], int]:
        """Wrapped rows and the scale they earned: as big as fits."""
        hit = self._laid.get(text)
        if hit is not None:
            return hit
        kept = "".join(
            ch for ch in normalize(text.lower())
            if cell(ch) is not None or ch == " ")
        kept = " ".join(kept.split())
        rows: list[str] = []
        scale = 1
        if kept:
            for try_scale in (2, 1):
                rows = wrap_text(kept, self.size - 4, try_scale)
                line_h = 7 * try_scale + 2
                if len(rows) * line_h - 2 <= self.size - 4:
                    scale = try_scale
                    break
            else:
                rows = wrap_text(kept, self.size - 4, 1)[-6:]
                scale = 1
        out = (rows, scale)
        self._laid[text] = out
        return out

    def frame_at(self, t: float) -> Image.Image:
        canvas = self.base.copy()
        text, t0, t1 = self.sheet.at(t)
        rows, scale = self._layout(text) if text else ([], 1)
        if rows:
            tokens = [w for row in rows for w in row.split()]
            n = max(1, len(tokens))
            span = min(2.4, max(0.6, (t1 - t0) * 0.55))
            step = span / n

            line_h = 7 * scale + 2
            block_h = len(rows) * line_h - 2
            y = (self.size - block_h) // 2
            shown = 0
            for row in rows:
                words = row.split()
                visible, newest_k = 0, 1.0
                for i in range(len(words)):
                    born = t0 + (shown + i) * step
                    if t >= born:
                        visible = i + 1
                        newest_k = min(1.0, (t - born) / self.RAMP)
                shown += len(words)
                if visible == 0:
                    y += line_h
                    continue
                # left-anchored, drawn as prefixes of the wrapped row so the
                # walk can never disagree with the wrap
                x = 2
                settled = " ".join(words[:visible - 1])
                if settled:
                    draw_text(canvas, settled, x, y, self.ink, scale)
                last = words[visible - 1]
                lx = x + (text_width(settled, scale) + 6 * scale if settled else 0)
                k = newest_k if visible == len(words) else 1.0
                ink = tuple(int(self.ink[i] * k + self.bg[i] * (1 - k))
                            for i in range(3))
                draw_text(canvas, last, lx, y, ink, scale)
                y += line_h
        return Image.fromarray(canvas, "RGB")
