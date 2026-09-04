"""ListenBrainz: the open scrobble ledger, and the one that needs no key.

The same idea as Last.fm (players report what they play to one account, the
wall asks that account) with one difference that matters here: reading a
user's "playing now" needs no API key and no token, just the username.
Web Scrobbler in a browser, Pano Scrobbler on Android, and most Last.fm
scrobblers can post to ListenBrainz as well, so YouTube Music, SoundCloud,
Amazon Music and the rest reach the wall through here from any computer.

Config:  [listenbrainz] user = "..."   (an account at listenbrainz.org is free)
Polled every few seconds; the limit is 30 requests per 10 s.
"""
from __future__ import annotations

import time
import urllib.parse

import requests

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art

API = "https://api.listenbrainz.org/1/user/{user}/playing-now"
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"


class ListenBrainzSource(NowPlayingSource):
    name = "listenbrainz"

    def __init__(self, user: str = ""):
        self.user = (user or "").strip()
        self._backoff_until = 0.0
        self._art_key = None
        self._art_url = None

    @property
    def configured(self) -> bool:
        return bool(self.user)

    def configure(self, user=None):
        if user is not None:
            self.user = user.strip()
        self._backoff_until = 0.0
        self._art_key = self._art_url = None

    def _art(self, key, title, artist, album, release_mbid):
        if key == self._art_key:
            return self._art_url
        url = None
        if release_mbid:
            cand = f"https://coverartarchive.org/release/{release_mbid}/front-500"
            try:
                if requests.head(cand, timeout=8, allow_redirects=True).status_code == 200:
                    url = cand
            except requests.RequestException:
                pass
        if not url and album:
            url = _itunes_art(f"{artist} {album}", "album")
        if not url:
            url = _itunes_art(f"{artist} {title}", "song")
        if url:
            self._art_key, self._art_url = key, url
        return url

    def get_current(self):
        if not self.user or time.time() < self._backoff_until:
            return None
        resp = requests.get(API.format(user=urllib.parse.quote(self.user)),
                            headers={"User-Agent": UA}, timeout=10)
        if resp.status_code == 429:
            self._backoff_until = time.time() + float(
                resp.headers.get("X-RateLimit-Reset-In", 30))
            return None
        if resp.status_code == 404:
            print(f"[listenbrainz] no such user {self.user!r}")
            self._backoff_until = time.time() + 300
            return None
        resp.raise_for_status()
        listens = (resp.json().get("payload") or {}).get("listens") or []
        if not listens:
            return None
        tm = listens[0].get("track_metadata") or {}
        title = tm.get("track_name") or "?"
        artist = tm.get("artist_name") or "?"
        album = tm.get("release_name") or ""
        info = tm.get("additional_info") or {}
        dur = info.get("duration_ms")
        if dur is None and isinstance(info.get("duration"), (int, float)):
            dur = info["duration"] * 1000
        key = (artist, album, title)
        return NowPlaying(
            track_id="listenbrainz:" + (info.get("recording_mbid") or f"{artist}|{title}"),
            title=title, artist=artist, album=album or "?",
            art_url=self._art(key, title, artist, album, info.get("release_mbid")),
            progress_ms=None, duration_ms=int(dur) if dur else None, is_playing=True,
        )
