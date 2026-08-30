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
    # lines sharing a timestamp collapse into one, or the earlier of the
    # pair never shows at all
    merged: list[tuple[float, str]] = []
    for t, text in out:
        if merged and t - merged[-1][0] < 0.05:
            prev_t, prev = merged[-1]
            merged[-1] = (prev_t, (prev + " " + text).strip())
        else:
            merged.append((t, text))
    return merged


def split_voices(lines):
    """Two voices out of one sheet: a line living entirely in parentheses
    is the second singer; a trailing parenthetical is an echo belonging to
    its line's moment. Each ad-lib owns a window to the next event."""
    mains, raw = [], []
    for t, text in lines:
        text = text.strip()
        if text.startswith("(") and text.endswith(")") and len(text) > 2:
            raw.append((t, text))
            continue
        if text.endswith(")") and "(" in text[1:]:
            cut = text.rindex("(")
            main, echo = text[:cut].strip(), text[cut:]
            if main:
                mains.append((t, main))
                raw.append((t, echo))
                continue
        mains.append((t, text))
    starts = sorted(t for t, _ in lines)
    adlibs = []
    for t, text in raw:
        nxt = next((x for x in starts if x > t + 0.05), t + 4)
        adlibs.append((t, min(nxt, t + 6), text))
    return mains, adlibs


class LyricSheet:
    """One track's synced lines, and where we are in them."""

    def __init__(self, lines: list[tuple[float, str]]):
        self.lines, self.adlibs = split_voices(lines)

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
    """Exact lookup, distrusted when its edit's length disagrees with the
    song, then a duration-ranked search. Transport errors retry with a
    breath between attempts, so a hiccup is never remembered forever as
    'this song has no words'. None means none exist."""
    import time as _time

    import requests
    base = "https://lrclib.net/api"
    for attempt in range(3):
        if attempt:
            _time.sleep(2 * attempt)
        try:
            params = {"artist_name": artist, "track_name": title}
            if album:
                params["album_name"] = album
            if duration_s:
                params["duration"] = int(duration_s)
            resp = requests.get(base + "/get", params=params, timeout=10)
            data = resp.json() if resp.status_code == 200 else None
            if data and data.get("syncedLyrics") and duration_s \
                    and abs((data.get("duration") or duration_s)
                            - duration_s) > 4:
                data = None          # right song, wrong edit: keep looking
            if not (data and data.get("syncedLyrics")):
                resp = requests.get(base + "/search",
                                    params={"artist_name": artist,
                                            "track_name": title},
                                    timeout=10)
                hits = resp.json() if resp.status_code == 200 else []
                synced = [h for h in hits if h.get("syncedLyrics")]
                if duration_s and synced:
                    data = min(synced, key=lambda h: abs(
                        (h.get("duration") or 1e9) - duration_s))
                else:
                    data = synced[0] if synced else None
            if not (data and data.get("syncedLyrics")):
                return None
            lines = parse_lrc(data["syncedLyrics"])
            return LyricSheet(lines) if lines else None
        except Exception:
            continue
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
    """The brat behaviour on the sleeve: a line starts huge and steps down
    in size as its words arrive and crowd it, lowercase, left-anchored,
    lettered over the cover dimmed to a quarter, each row throwing its own
    shadow. Layout is recomputed for exactly the words visible so far."""

    DIM = 0.26
    RAMP = 0.12

    def __init__(self, size: int, art, sheet: LyricSheet,
                 color: str = "#f4f1ea"):
        self.size = size
        self.sheet = sheet
        if art is not None:
            self.base = np.asarray(
                art.convert("RGB").resize((size, size), Image.LANCZOS),
                dtype=np.float32) * self.DIM
        else:
            self.base = np.zeros((size, size, 3), dtype=np.float32)
        self.ink = (244, 241, 234)
        self._laid: dict[tuple, tuple] = {}

    def _tokens(self, text: str) -> list[str]:
        kept = "".join(
            ch for ch in normalize(text.lower())
            if cell(ch) is not None or ch == " ")
        return kept.split()

    def _layout(self, key, tokens: list[str]):
        hit = self._laid.get(key)
        if hit is not None:
            return hit
        joined = " ".join(tokens)
        rows, scale = None, 1
        for s_ in (4, 3, 2, 1):
            if text_width(joined, s_) <= self.size - 4:
                rows, scale = [joined], s_
                break
        if rows is None:
            for s_ in (3, 2, 1):
                cand = wrap_text(joined, self.size - 4, s_)
                if (len(cand) * (7 * s_ + 2) - 2 <= self.size - 14
                        and " ".join(cand) == joined):
                    rows, scale = cand, s_
                    break
        if rows is None:
            rows, scale = wrap_text(joined, self.size - 4, 1)[-5:], 1
        if len(self._laid) > 256:
            self._laid.clear()
        self._laid[key] = (rows, scale)
        return rows, scale

    def _foot(self, canvas, text: str):
        """The second singer's row: one row at the panel's foot, never
        more, parentheses kept because that is how the second voice
        writes. Empty when nobody is answering."""
        tokens = self._tokens(text)
        if not tokens:
            return
        joined = " ".join(tokens)
        rows = wrap_text(joined, self.size - 4, 1)
        row = rows[0] if rows else joined
        x = (self.size - min(self.size - 4, text_width(row, 1))) // 2
        y = self.size - 9
        u8 = np.zeros((self.size, self.size, 3), dtype=np.uint8)
        draw_text(u8, row, x + 1, y + 1, (255, 255, 255), 1)
        mask = u8.sum(axis=2) > 0
        canvas[mask] *= 0.35
        foot_ink = tuple(int(c * 0.66) for c in self.ink)
        u8[:] = 0
        draw_text(u8, row, x, y, foot_ink, 1)
        mask = u8.sum(axis=2) > 0
        canvas[mask] = u8[mask]

    def frame_at(self, t: float) -> Image.Image:
        canvas = self.base.copy()
        text, t0, t1 = self.sheet.at(t)
        # the foot row's claimants: a live ad-lib outranks the preview
        adlib = next((a[2] for a in self.sheet.adlibs
                      if a[0] <= t < a[1]), None)
        tokens = self._tokens(text) if text else []
        if tokens:
            n = len(tokens)
            span = min(2.4, max(0.6, (t1 - t0) * 0.55))
            step = span / n
            visible, newest_k = 0, 1.0
            for i in range(n):
                born = t0 + i * step
                if t >= born:
                    visible = i + 1
                    newest_k = min(1.0, (t - born) / self.RAMP)
            if visible:
                rows, scale = self._layout((t0, visible), tokens[:visible])
                line_h = 7 * scale + 2
                y = max(1, (self.size - 12 - (len(rows) * line_h - 2)) // 2)
                drawn = 0
                for row in rows:
                    words = row.split()
                    # the row's shadow, then its ink
                    u8 = np.zeros((self.size, self.size, 3), dtype=np.uint8)
                    draw_text(u8, row, 3, y + 1, (255, 255, 255), scale)
                    mask = u8.sum(axis=2) > 0
                    canvas[mask] *= 0.3
                    drawn += len(words)
                    last_row = drawn >= visible
                    settled = " ".join(words[:-1]) if last_row else row
                    if settled:
                        u8[:] = 0
                        draw_text(u8, settled, 2, y, self.ink, scale)
                        mask = u8.sum(axis=2) > 0
                        canvas[mask] = u8[mask]
                    if last_row and words:
                        lx = 2 + (text_width(settled, scale) + 6 * scale
                                  if settled else 0)
                        k = max(0.3, newest_k)
                        ink = tuple(int(c * k) for c in self.ink)
                        u8[:] = 0
                        draw_text(u8, words[-1], lx, y, ink, scale)
                        mask = u8.sum(axis=2) > 0
                        canvas[mask] = u8[mask]
                    y += line_h
        if adlib:
            self._foot(canvas, adlib)
        return Image.fromarray(np.clip(canvas, 0, 255).astype(np.uint8), "RGB")
