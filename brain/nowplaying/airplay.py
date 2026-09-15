"""AirPlay to the wall.

shairport-sync makes the Pi an AirPlay receiver called "Wall". Add it to
any AirPlay group from an iPhone, a Mac or an Apple TV and the wall is
handed the exact title, artist, album, artwork and position of whatever is
playing, with no account, no key and no guessing: the source tells it.
The wall does not have to make a sound (the dummy output backend), or it
can, through a USB DAC (the alsa backend). docs/AIRPLAY.md has the setup.

This is the brain's side: a reader on shairport-sync's metadata pipe, a
FIFO of records shaped like

    <item><type>636f7265</type><code>6d696e6d</code><length>6</length>
    <data encoding="base64">
    TmlnaHRz</data></item>

where type and code are four-character codes written as eight hex digits
("core" for what the source sent, "ssnc" for what shairport-sync itself
says) and the data is base64. The codes that matter:

    core  minm title   asar artist   asal album   asgn genre
          astm length in ms (four bytes, big-endian)   mper persistent id
    ssnc  mdst/mden  a bundle of core records begins/ends
          PICT       the artwork, JPEG or PNG bytes
          prgr       "start/current/end", RTP timestamps at 44100 a second
          pbeg pfls prsm pend   play begins, is flushed (paused), resumes, ends
          snam snua  the client's name and user agent   disc  it disconnected

The answer is a NowPlaying with track_id "airplay:<hash>" that changes
when the artwork arrives (it comes a beat after the title), so the wall
shows the sleeve as soon as there is one. Artwork is served on the control
port (GET /art/airplay/<key>.jpg) for the phone, and handed to the brain's
own fetcher without a round trip.
"""
from __future__ import annotations

import base64
import hashlib
import os
import re
import socket
import subprocess
import threading
import time

from . import NowPlaying, NowPlayingSource
from ..art import fetch as art_fetch

PIPE = "/tmp/shairport-sync-metadata"
RTP_HZ = 44100.0
ART_KEEP = 4                     # artworks kept for the phone to fetch
BUF_MAX = 8 * 1024 * 1024        # a runaway pipe never eats the brain

_ITEM = re.compile(rb"<item><type>([0-9a-fA-F]{8})</type><code>([0-9a-fA-F]{8})</code>"
                   rb"<length>(\d+)</length>\s*(?:<data encoding=\"base64\">\s*(.*?)\s*</data>)?\s*</item>",
                   re.S)


def code_of(hex8: bytes | str) -> str:
    try:
        return bytes.fromhex(hex8.decode() if isinstance(hex8, bytes) else hex8).decode("latin-1")
    except ValueError:
        return "?"


class Parser:
    """Bytes in, (type, code, data) records out, across any chunking."""

    def __init__(self):
        self.buf = b""

    def feed(self, chunk: bytes) -> list[tuple[str, str, bytes]]:
        self.buf += chunk
        out = []
        while True:
            m = _ITEM.search(self.buf)
            if not m:
                break
            t, c, n, d = m.groups()
            if int(n) > 0 and d is None:
                # the record says data is coming but it has not: not this one
                # yet, unless the stream really is malformed past this point
                nxt = self.buf.find(b"<item>", m.start() + 6)
                if nxt < 0:
                    break
                self.buf = self.buf[nxt:]
                continue
            try:
                data = base64.b64decode(d) if d else b""
            except ValueError:
                data = b""
            out.append((code_of(t), code_of(c), data))
            self.buf = self.buf[m.end():]
        if len(self.buf) > BUF_MAX:
            self.buf = self.buf[-BUF_MAX // 2:]
        return out


def _running() -> bool:
    try:
        return subprocess.run(["pgrep", "-x", "shairport-sync"], capture_output=True, timeout=3).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class AirPlaySource(NowPlayingSource):
    name = "airplay"

    def __init__(self, pipe: str = PIPE, port: int = 8788, host: str | None = None, clock=None):
        self.pipe = pipe
        self.port = port
        self.host = host or (socket.gethostname().split(".")[0] + ".local")
        self._clock = clock or time.monotonic
        self._lock = threading.Lock()
        self.title = self.artist = self.album = self.genre = ""
        self.duration_ms: int | None = None
        self.persistent = ""
        self._pending: dict = {}
        self._prgr = None                # (start, current, end, at)
        self.playing = False
        self.active = False              # a stream is on (between pbeg and pend)
        self.client = ""
        self.user_agent = ""
        self.volume: float | None = None
        self.art_key = ""
        self.art_ext = "jpg"
        self.arts: dict[str, tuple[bytes, str]] = {}   # key -> (bytes, mime), the last few
        self.reading = False
        self.error: str | None = None
        self.last_item_at: float | None = None
        self.records = 0
        self._thread = threading.Thread(target=self._loop, name="airplay", daemon=True)

    def start(self) -> "AirPlaySource":
        self._thread.start()
        return self

    # ---- the pipe --------------------------------------------------------------------------------
    def _loop(self):
        parser = Parser()
        while True:
            if not os.path.exists(self.pipe):
                self.error = f"no metadata pipe at {self.pipe}; is shairport-sync installed and its metadata on?"
                time.sleep(10)
                continue
            try:
                # opening a FIFO for reading blocks until shairport-sync opens
                # it for writing, which it does when a stream begins
                with open(self.pipe, "rb", buffering=0) as fh:
                    self.reading, self.error = True, None
                    while True:
                        chunk = fh.read(65536)
                        if not chunk:
                            break            # the writer closed: shairport-sync stopped
                        for t, c, d in parser.feed(chunk):
                            self.handle(t, c, d)
            except OSError as exc:
                self.error = f"{type(exc).__name__}: {exc}"
                time.sleep(3)
            finally:
                self.reading = False
                parser.buf = b""
                self._end()

    # ---- the records -------------------------------------------------------------------------------
    def handle(self, t: str, c: str, d: bytes):
        now = self._clock()
        with self._lock:
            self.last_item_at = now
            self.records += 1
            if t == "core":
                text = d.decode("utf-8", "replace").strip()
                if c == "minm":
                    self._pending["title"] = text
                elif c == "asar":
                    self._pending["artist"] = text
                elif c == "asal":
                    self._pending["album"] = text
                elif c == "asgn":
                    self._pending["genre"] = text
                elif c == "astm" and len(d) >= 4:
                    self._pending["duration_ms"] = int.from_bytes(d[:4], "big")
                elif c == "mper" and d:
                    self._pending["persistent"] = d.hex()
                return
            if t != "ssnc":
                return
            if c == "mdst":
                self._pending = {}
            elif c == "mden":
                self._commit()
            elif c == "PICT":
                self._picture(d)
            elif c == "pbeg":
                self.playing, self.active = True, True
            elif c in ("prsm", "pffr"):
                self.playing = True
                self.active = True
            elif c == "pfls":
                self.playing = False
            elif c == "pend":
                self.playing, self.active = False, False
                self._prgr = None
            elif c == "prgr":
                self._progress(d, now)
            elif c == "snam":
                self.client = d.decode("utf-8", "replace").strip()
            elif c == "snua":
                self.user_agent = d.decode("utf-8", "replace").strip()
            elif c == "pvol":
                try:
                    self.volume = float(d.decode().split(",")[0])
                except (ValueError, IndexError):
                    pass
            elif c == "disc":
                self._end_locked()

    def _commit(self):
        p = self._pending
        if not p:
            return
        was = (self.title, self.artist, self.album)
        self.title = p.get("title", self.title if "title" not in p else "")
        self.artist = p.get("artist", self.artist)
        self.album = p.get("album", self.album)
        self.genre = p.get("genre", self.genre)
        self.duration_ms = p.get("duration_ms", self.duration_ms)
        self.persistent = p.get("persistent", self.persistent)
        if (self.title, self.artist, self.album) != was:
            # a new song: its artwork is on its way; the old one is not its
            self.art_key = ""
            self._prgr = None
        self._pending = {}
        if self.title:
            self.active = True

    def _picture(self, d: bytes):
        if not d:
            self.art_key = ""
            return
        mime = "image/png" if d[:4] == b"\x89PNG" else "image/jpeg"
        key = hashlib.sha1(d).hexdigest()[:12]
        self.art_key, self.art_ext = key, ("png" if mime == "image/png" else "jpg")
        self.arts[key] = (d, mime)
        for old in list(self.arts)[:-ART_KEEP]:
            self.arts.pop(old, None)
            art_fetch.LOCAL.pop(self._url_for(old, "png"), None)
            art_fetch.LOCAL.pop(self._url_for(old, "jpg"), None)
        art_fetch.LOCAL[self.art_url()] = d

    def _progress(self, d: bytes, now: float):
        try:
            start, cur, end = (int(x) for x in d.decode().strip().split("/"))
        except (ValueError, UnicodeDecodeError):
            return
        self._prgr = (start, cur, end, now)

    def _end_locked(self):
        self.playing = self.active = False
        self._prgr = None
        self.client = self.user_agent = ""

    def _end(self):
        with self._lock:
            self._end_locked()

    # ---- the answer ---------------------------------------------------------------------------------
    def _url_for(self, key: str, ext: str) -> str:
        return f"http://{self.host}:{self.port}/art/airplay/{key}.{ext}"

    def art_url(self) -> str | None:
        return self._url_for(self.art_key, self.art_ext) if self.art_key else None

    def art(self, key: str) -> tuple[bytes, str] | None:
        return self.arts.get(key)

    def progress(self) -> tuple[int | None, int | None]:
        """(position, length) in ms from the last prgr, advanced by the
        clock while playing; the length from astm when prgr has none."""
        dur = self.duration_ms
        if self._prgr is None:
            return None, dur
        start, cur, end, at = self._prgr
        pos = (cur - start) / RTP_HZ * 1000.0
        if self.playing:
            pos += (self._clock() - at) * 1000.0
        total = (end - start) / RTP_HZ * 1000.0 if end > start else None
        total_ms = int(total) if total else dur
        pos_ms = int(max(0.0, pos))
        if total_ms:
            pos_ms = min(pos_ms, total_ms)
        return pos_ms, total_ms

    def get_current(self):
        with self._lock:
            if not self.active or not self.title:
                return None
            key = hashlib.sha1(f"{self.persistent}|{self.title}|{self.artist}|{self.album}|{self.art_key}"
                               .encode()).hexdigest()[:12]
            pos, total = self.progress()
            return NowPlaying(
                track_id=f"airplay:{key}", title=self.title, artist=self.artist or "?",
                album=self.album or "?", art_url=self.art_url(), progress_ms=pos, duration_ms=total,
                is_playing=self.playing)

    def status(self) -> dict:
        with self._lock:
            state = "playing" if self.active and self.playing else "paused" if self.active else "idle"
            return {"pipe": self.pipe, "pipe_exists": os.path.exists(self.pipe), "reading": self.reading,
                    "running": _running(), "state": state, "connected_from": self.client,
                    "user_agent": self.user_agent, "volume": self.volume,
                    "last": (f"{self.artist} — {self.title}" if self.title else None),
                    "records": self.records, "error": self.error}
