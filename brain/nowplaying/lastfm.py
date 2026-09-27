"""Read Last.fm's public listening feed without accepting stale account replies.

The read API does not authenticate the listener or grant scrobbling permission.
Only an explicit nowplaying flag may drive the wall; the latest completed
scrobble remains history. Public status never includes the API key or a raw
HTTP exception (requests' exception URLs can contain that key).
"""
import math
import threading
import time
from urllib.parse import urlparse

import requests

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art

API = "https://ws.audioscrobbler.com/2.0/"
CACHE_S = 5.0
FRESH_S = 30.0


def _text(value, limit=300):
    return value.strip()[:limit] if isinstance(value, str) else ""


def _https_image(value):
    value = _text(value, 2048)
    try:
        parsed = urlparse(value)
        return value if parsed.scheme == "https" and parsed.netloc and not parsed.username and not parsed.password else None
    except ValueError:
        return None


def _retry_seconds(value):
    try:
        seconds = float(value)
        return min(3600.0, max(5.0, seconds)) if math.isfinite(seconds) else 60.0
    except (TypeError, ValueError):
        return 60.0


class LastfmSource(NowPlayingSource):
    name = "lastfm"

    def __init__(self, api_key: str = "", user: str = ""):
        self._lock = threading.RLock()
        self.api_key = _text(api_key, 64)
        self.user = _text(user, 64)
        self._generation = 0
        self._flight = None
        self._backoff_until = 0.0
        self._asked_at = None
        self._checked_at = None
        self._last = None
        self._last_listen = None
        self._state = "ready"
        self._problem = None
        self._art_key = None
        self._art_url = None

    @property
    def configured(self) -> bool:
        with self._lock:
            return bool(self.api_key and self.user)

    def configure(self, api_key=None, user=None):
        with self._lock:
            key = self.api_key if api_key is None else _text(api_key, 64)
            name = self.user if user is None else _text(user, 64)
            if (key, name) == (self.api_key, self.user):
                return
            self.api_key, self.user = key, name
            self._generation += 1
            # An old request may finish, but cannot affect a new account's state.
            self._flight = None
            self._backoff_until, self._asked_at = 0.0, None
            self._checked_at = self._last = self._last_listen = None
            self._state, self._problem = "ready", None
            self._art_key = self._art_url = None

    def status(self):
        with self._lock:
            wait = max(0.0, self._backoff_until - time.monotonic())
            state = self._state
            fresh = self._asked_at is not None and time.monotonic() - self._asked_at <= FRESH_S
            if not self.user:
                state = "unlinked" if self.api_key else "unconfigured"
            elif not self.api_key:
                state = "needs_key"
            elif self._flight is not None:
                state = "checking"
            elif state in ("playing", "idle") and not fresh:
                state = "ready"
            current = self._track_dict(self._last) if self._last and fresh and state == "playing" else None
            return {"user": self.user, "key_set": bool(self.api_key), "state": state,
                    "problem": self._problem, "checked_at": self._checked_at,
                    "retry_after": round(wait, 1) if wait else None,
                    "can_retry": self.configured and self._flight is None and wait == 0,
                    "current": current,
                    "last_listen": dict(self._last_listen) if self._last_listen else None}

    @staticmethod
    def _track_dict(track):
        return {"title": track.title, "artist": track.artist, "album": track.album,
                "art_url": track.art_url}

    def _begin(self, force=False):
        with self._lock:
            now = time.monotonic()
            if not self.configured or self._flight is not None or now < self._backoff_until:
                return None
            if not force and self._asked_at is not None and now - self._asked_at < CACHE_S:
                return None
            token = object()
            self._flight = token
            self._asked_at = now
            return token, self._generation, self.api_key, self.user

    def retry(self):
        """Check once even when an earlier source in the chain is playing."""
        flight = self._begin(force=True)
        if flight is None:
            return False
        try:
            threading.Thread(target=self._finish, args=(flight,), name="lastfm-check", daemon=True).start()
        except RuntimeError:
            with self._lock:
                if self._flight is flight[0]:
                    self._flight = None
                    self._state = "unavailable"
                    self._problem = "The wall could not start this check. Try again shortly."
                    self._backoff_until = time.monotonic() + 5
            return False
        return True

    def get_current(self):
        flight = self._begin()
        if flight is not None:
            return self._finish(flight)
        with self._lock:
            if self._asked_at is None or time.monotonic() - self._asked_at > FRESH_S:
                return None
            return self._last

    def _finish(self, flight):
        token, generation, key, user = flight
        result, recent, state, problem, backoff = None, None, "unavailable", "Last.fm could not be reached. Try again shortly.", 15.0
        try:
            result, recent, state, problem, backoff = self._fetch(key, user, generation)
        except Exception:
            # Do not expose response bodies, request URLs, API keys or usernames
            # through the generic source-chain exception logger.
            pass
        with self._lock:
            if generation != self._generation or token is not self._flight:
                return None
            self._flight = None
            self._last = result
            if recent is not None:
                self._last_listen = recent
            elif state == "idle":
                self._last_listen = None
            self._state, self._problem = state, problem
            self._checked_at = time.time()
            self._backoff_until = time.monotonic() + backoff if backoff else 0.0
        return result

    def _art(self, title, artist, album, lastfm_url, generation):
        art_key = (artist, album, title)
        with self._lock:
            if generation != self._generation:
                return None
            if art_key == self._art_key and (not lastfm_url or lastfm_url == self._art_url):
                return self._art_url
        # Prefer the source's actual sleeve over a fuzzy catalogue match. Search
        # is only a fallback when the reporting player supplied no artwork.
        url = lastfm_url
        if not url:
            url = _https_image(_itunes_art(f"{artist} {album}", "album")) if album else None
            url = url or _https_image(_itunes_art(f"{artist} {title}", "song"))
        with self._lock:
            if generation == self._generation:
                self._art_key, self._art_url = art_key, url
        return url

    def _fetch(self, key, user, generation):
        response = requests.get(API, params={"method": "user.getrecenttracks", "user": user,
                                             "api_key": key, "format": "json", "limit": 2}, timeout=10)
        if response.status_code == 429:
            return None, None, "rate_limited", "Last.fm asked the wall to wait before checking again.", _retry_seconds(response.headers.get("Retry-After"))
        if response.status_code in (401, 403):
            return None, None, "refused", "Last.fm refused access. Check the API key and your profile privacy.", 60.0
        response.raise_for_status()
        payload = response.json()
        if not isinstance(payload, dict):
            raise ValueError("invalid Last.fm response")
        if payload.get("error"):
            try:
                code = int(payload["error"])
            except (ValueError, TypeError):
                code = 0
            if code == 29:
                return None, None, "rate_limited", "Last.fm asked the wall to wait before checking again.", 60.0
            if code in (6, 7):
                return None, None, "not_found", "This Last.fm profile could not be found. Check the username.", 60.0
            if code in (4, 9, 10, 13, 17, 26):
                problem = "Last.fm cannot share this profile. Make recent listening public in Last.fm." if code == 17 else "Last.fm refused this API key. Replace it with an active key."
                return None, None, "refused", problem, 60.0
            return None, None, "unavailable", "Last.fm is temporarily unavailable. Try again shortly.", 15.0
        recent = payload.get("recenttracks")
        if not isinstance(recent, dict) or "track" not in recent:
            raise ValueError("missing Last.fm tracks")
        tracks = recent["track"]
        if isinstance(tracks, dict):
            tracks = [tracks]
        if not isinstance(tracks, list):
            raise ValueError("invalid Last.fm tracks")
        latest = None
        playing = None
        for item in tracks[:2]:
            if not isinstance(item, dict):
                raise ValueError("invalid Last.fm track")
            title = _text(item.get("name"))
            artist_block = item.get("artist")
            album_block = item.get("album")
            artist = _text(artist_block.get("#text") if isinstance(artist_block, dict) else artist_block)
            album = _text(album_block.get("#text") if isinstance(album_block, dict) else album_block)
            if not title or not artist:
                raise ValueError("incomplete Last.fm track")
            images = item.get("image") or []
            art = next((_https_image(image.get("#text")) for image in reversed(images)
                        if isinstance(image, dict) and _https_image(image.get("#text"))), None) if isinstance(images, list) else None
            attr = item.get("@attr")
            flag = attr.get("nowplaying") if isinstance(attr, dict) else None
            nowplaying = flag == "true" or flag is True
            if nowplaying and playing is None:
                art = self._art(title, artist, album, art, generation)
                playing = NowPlaying(track_id=f"lastfm:{artist}|{title}", title=title, artist=artist,
                                     album=album or "?", art_url=art, progress_ms=None,
                                     duration_ms=None, is_playing=True)
            elif not nowplaying and latest is None:
                date = item.get("date")
                try:
                    at = int(date.get("uts")) if isinstance(date, dict) else None
                    if at is not None and not 0 < at <= time.time() + 300:
                        at = None
                except (TypeError, ValueError, OverflowError):
                    at = None
                latest = {"title": title, "artist": artist, "album": album, "art_url": art, "at": at}
        return playing, latest, "playing" if playing else "idle", None, 0.0
