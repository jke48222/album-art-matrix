"""What the phone tells the wall directly.

The phone reads its own Music player and posts here; the wall needs no Mac
in the path. A push is trusted for TTL seconds and then forgotten, so a
phone that died mid-song cannot pin the wall to it: the app heartbeats every
15 seconds while music plays.

Artwork: the app sends the catalog id and, when it has one, an art URL. When
it does not, the iTunes search ladder from the Apple Music adapter finds one.
"""
import threading
import time

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art, _itunes_lookup_art

TTL = 40.0


class PushedSource(NowPlayingSource):
    name = "phone"

    def __init__(self):
        self._lock = threading.Lock()
        self._at = None          # monotonic of the last push
        self._data = None
        self._art_key = None
        self._art_url = None

    # ---- what the control API calls --------------------------------------
    def push(self, data: dict):
        with self._lock:
            self._at = time.monotonic()
            self._data = dict(data)

    @property
    def phone_age(self):
        """Seconds since the phone last spoke, or None if it never has. The
        away logic reads this: it is presence, not music."""
        with self._lock:
            return None if self._at is None else time.monotonic() - self._at

    # ---- the adapter --------------------------------------------------------
    def _art(self, title, artist, album, store_id=None):
        key = (artist, album, title, store_id)
        if key == self._art_key:
            return self._art_url
        clean = (album or "").removesuffix(" - Single").removesuffix(" - EP")
        # the id names the exact release; the searches are the fallback
        url = (_itunes_lookup_art(store_id)
               or _itunes_art(f"{artist} {clean}", "album")
               or _itunes_art(f"{artist} {title}", "song")
               or _itunes_art(title, "song"))
        if url:
            self._art_key, self._art_url = key, url
        return url

    def get_current(self):
        with self._lock:
            at, d = self._at, self._data
        if d is None or at is None or time.monotonic() - at > TTL:
            return None
        if not d.get("track"):
            return None
        playing = bool(d.get("playing", True))
        title = d["track"]
        artist = d.get("artist", "?")
        album = d.get("album", "?")
        art = d.get("art") or self._art(title, artist, album, d.get("id"))
        prog = d.get("progress_ms")
        if prog is not None:
            # a paused song does not advance; only a playing one is aged
            if playing:
                prog = int(prog + (time.monotonic() - at) * 1000)
            if d.get("duration_ms"):
                prog = min(int(prog), int(d["duration_ms"]))
        return NowPlaying(
            track_id="applemusic:" + (str(d.get("id")) if d.get("id") else f"{artist}|{title}"),
            title=title, artist=artist, album=album, art_url=art,
            progress_ms=prog, duration_ms=d.get("duration_ms"), is_playing=playing,
        )
