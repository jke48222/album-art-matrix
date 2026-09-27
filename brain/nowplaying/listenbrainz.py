"""Public ListenBrainz now-playing reader; writing listens has a separate token."""
from __future__ import annotations

import math
import threading
import time
import urllib.parse
import uuid

import requests

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art

API = "https://api.listenbrainz.org/1/user/{user}/playing-now"
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"
CACHE_S = 5.0
FRESH_PLAYING_S = 30.0


class ListenBrainzSource(NowPlayingSource):
    name = "listenbrainz"

    def __init__(self, user: str = ""):
        self.user = (user or "").strip()
        self._lock = threading.RLock()
        self._request_lock = threading.Lock()
        self._generation = 0
        self._backoff_until = 0.0
        self._asked_at, self._last = 0.0, None
        self._fresh_at = None
        self._art_key = self._art_url = None
        self._state = "checking" if self.user else "unlinked"
        self._problem = None
        self._checked_at = None
        self._retrying = False

    @property
    def configured(self) -> bool:
        return bool(self.user)

    def configure(self, user=None):
        with self._lock:
            if user is None or user.strip() == self.user:
                return
            self.user = user.strip()
            self._generation += 1
            self._backoff_until = self._asked_at = 0.0
            self._last = self._art_key = self._art_url = None
            self._fresh_at = None
            self._state = "checking" if self.user else "unlinked"
            self._problem = self._checked_at = None

    def retry(self):
        """A user check also works when a higher-priority source is playing."""
        with self._lock:
            if self._retrying or not self.user or time.monotonic() < self._backoff_until:
                return False
            self._retrying = True
            self._asked_at = 0.0
            self._state = "checking"
        def check():
            try:
                self.get_current()
            finally:
                with self._lock:
                    self._retrying = False
        threading.Thread(target=check, name="listenbrainz-check", daemon=True).start()
        return True

    def _expire_playing(self, now):
        # A higher-priority player may keep this reader out of the source
        # chain. Its last report is no longer evidence that music still plays.
        if self._last is not None and (self._fresh_at is None or now - self._fresh_at >= FRESH_PLAYING_S):
            self._last = None
            if self._state == "playing":
                self._state = "checking" if self.user else "unlinked"
                self._problem = None

    def status(self):
        with self._lock:
            self._expire_playing(time.monotonic())
            p = self._last
            return {"user": self.user, "read_state": self._state,
                    "read_problem": self._problem, "read_checked_at": self._checked_at,
                    "read_playing": ({"title": p.title, "artist": p.artist,
                                      "album": p.album} if p else None)}

    def _art(self, key, title, artist, album, release_mbid, generation):
        with self._lock:
            if key == self._art_key:
                return self._art_url
        url = None
        try:
            mbid = str(uuid.UUID(str(release_mbid))) if release_mbid else None
        except (ValueError, AttributeError):
            mbid = None
        if mbid:
            cand = f"https://coverartarchive.org/release/{mbid}/front-500"
            try:
                if requests.head(cand, timeout=8, allow_redirects=True).status_code == 200:
                    url = cand
            except requests.RequestException:
                pass
        try:
            if not url and album:
                url = _itunes_art(f"{artist} {album}", "album")
            if not url:
                url = _itunes_art(f"{artist} {title}", "song")
        except (requests.RequestException, ValueError):
            pass
        with self._lock:
            if generation == self._generation:
                self._art_key, self._art_url = key, url
        return url

    def get_current(self):
        with self._lock:
            now = time.monotonic()
            self._expire_playing(now)
            if not self.user:
                return None
            if now < self._backoff_until:
                return None
            if now - self._asked_at < CACHE_S:
                return self._last
            generation, user = self._generation, self.user
        if not self._request_lock.acquire(blocking=False):
            with self._lock:
                self._expire_playing(time.monotonic())
                return self._last
        try:
            with self._lock:
                if generation != self._generation:
                    return None
                self._asked_at = time.monotonic()
            playing, state, problem, backoff = self._fetch(user, generation)
            with self._lock:
                if generation != self._generation:
                    return None
                self._last, self._state, self._problem = playing, state, problem
                self._fresh_at = time.monotonic() if playing is not None else None
                self._checked_at = time.time()
                self._backoff_until = time.monotonic() + backoff if backoff else 0.0
                return playing
        finally:
            self._request_lock.release()

    def _fetch(self, user, generation):
        try:
            resp = requests.get(API.format(user=urllib.parse.quote(user, safe="")),
                                headers={"User-Agent": UA}, timeout=10)
            if resp.status_code == 429:
                try:
                    wait = float(resp.headers.get("X-RateLimit-Reset-In", 30))
                    wait = min(3600.0, max(1.0, wait)) if math.isfinite(wait) else 30.0
                except (TypeError, ValueError):
                    wait = 30.0
                return None, "rate_limited", "ListenBrainz asked the wall to wait before checking again.", wait
            if resp.status_code == 404:
                return None, "refused", "This ListenBrainz username was not found.", 0.0
            if resp.status_code in (401, 403):
                return None, "refused", "ListenBrainz did not allow this request.", 30.0
            resp.raise_for_status()
            data = resp.json()
            payload = data.get("payload") if isinstance(data, dict) else None
            if not isinstance(payload, dict) or not isinstance(payload.get("listens"), list):
                return None, "unavailable", "ListenBrainz returned an unreadable listening status.", 30.0
            listens = payload["listens"]
            if not listens:
                return None, "ready", None, 0.0
            tm = listens[0].get("track_metadata") if isinstance(listens[0], dict) else None
            if not isinstance(tm, dict) or not isinstance(tm.get("track_name"), str) or not isinstance(tm.get("artist_name"), str):
                return None, "unavailable", "The current song could not be read.", 30.0
            title, artist = tm["track_name"], tm["artist_name"]
            album = tm.get("release_name") if isinstance(tm.get("release_name"), str) else ""
            info = tm.get("additional_info") if isinstance(tm.get("additional_info"), dict) else {}
            raw = info.get("duration_ms", (info.get("duration") or 0) * 1000 if isinstance(info.get("duration"), (int, float)) else 0)
            duration = int(raw) if isinstance(raw, (int, float)) and math.isfinite(raw) and 0 < raw < 86_400_000 else None
            track = NowPlaying(track_id=f"listenbrainz:{artist}|{album}|{title}", title=title,
                               artist=artist, album=album or "?", progress_ms=None,
                               art_url=self._art((artist, album, title), title, artist, album,
                                                 info.get("release_mbid"), generation),
                               duration_ms=duration, is_playing=True)
            return track, "playing", None, 0.0
        except requests.RequestException:
            return None, "offline", "The wall cannot reach ListenBrainz. It will check again.", 30.0
        except (ValueError, TypeError, AttributeError):
            return None, "unavailable", "ListenBrainz returned an unreadable listening status.", 30.0
