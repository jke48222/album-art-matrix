"""Last.fm: one account that Spotify, Tidal and Deezer all report to.

Those services scrobble to Last.fm on their own once linked at last.fm, and
Last.fm marks the track in progress as "now playing" within seconds of it
starting. Apple Music gets here only through a scrobbling app on the phone,
which is why the phone push and the account tier come first in the chain.

Config:  [lastfm] api_key = "...", user = "..."   (a key is free at
last.fm/api/account/create). Polled every few seconds; Last.fm allows far
more than that.
"""
import time

import requests

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art

API = "https://ws.audioscrobbler.com/2.0/"


class LastfmSource(NowPlayingSource):
    name = "lastfm"

    def __init__(self, api_key: str = "", user: str = ""):
        self.api_key = (api_key or "").strip()
        self.user = (user or "").strip()
        self._backoff_until = 0.0
        self._art_key = None
        self._art_url = None

    @property
    def configured(self) -> bool:
        return bool(self.api_key and self.user)

    def configure(self, api_key=None, user=None):
        """New details from the phone; the next poll uses them."""
        if api_key is not None:
            self.api_key = api_key.strip()
        if user is not None:
            self.user = user.strip()
        self._backoff_until = 0.0
        self._art_key = self._art_url = None

    def _art(self, title, artist, album, lastfm_url):
        # Last.fm's own image tops out at 300 px; the iTunes ladder finds the
        # 600 px sleeve when it can, and the 300 is the fallback.
        key = (artist, album, title)
        if key == self._art_key:
            return self._art_url
        url = (_itunes_art(f"{artist} {album}", "album") if album else None) \
            or _itunes_art(f"{artist} {title}", "song") or lastfm_url
        if url:
            self._art_key, self._art_url = key, url
        return url

    def get_current(self):
        if not self.api_key or not self.user or time.time() < self._backoff_until:
            return None
        resp = requests.get(API, params={
            "method": "user.getrecenttracks", "user": self.user,
            "api_key": self.api_key, "format": "json", "limit": 1,
        }, timeout=10)
        if resp.status_code == 429:
            self._backoff_until = time.time() + 60
            return None
        resp.raise_for_status()
        tracks = ((resp.json().get("recenttracks") or {}).get("track")) or []
        if not tracks:
            return None
        t = tracks[0]
        if (t.get("@attr") or {}).get("nowplaying") != "true":
            return None
        title = t.get("name") or "?"
        artist = (t.get("artist") or {}).get("#text") or "?"
        album = (t.get("album") or {}).get("#text") or ""
        images = t.get("image") or []
        lastfm_art = next((i.get("#text") for i in reversed(images) if i.get("#text")), None)
        return NowPlaying(
            track_id=f"lastfm:{artist}|{title}",
            title=title, artist=artist, album=album or "?",
            art_url=self._art(title, artist, album, lastfm_art),
            progress_ms=None, duration_ms=None, is_playing=True,
        )
