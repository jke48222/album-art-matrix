"""Whatever this Mac is playing, read from macOS's own Now Playing.

The Mac keeps one Now Playing item for the whole machine, the one Control
Centre shows: Spotify's app, TIDAL, a browser tab on YouTube Music or
SoundCloud or Amazon Music, VLC, all of them land there, artwork included.
Apple closed that door to ordinary programs in macOS 15.4; `media-control`
(brew install media-control, github.com/ungive/mediaremote-adapter) is the
maintained way back through it, and this adapter shells out to it.

Music.app is left alone here: the Apple Music adapter reads it directly and
knows its persistent ids and catalog artwork. This tier is for everything
else, which is why it sits after "Music playing" and before the account view.

Artwork arrives as bytes, not a URL, so it goes out as a data: URL. The
reporter turns that into a small http URL the Pi can fetch; a brain running
on the Mac itself decodes it directly (art/fetch.py).
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone

from . import NowPlaying, NowPlayingSource
from .applemusic import _itunes_art

CANDIDATES = ("/opt/homebrew/bin/media-control", "/usr/local/bin/media-control")
SKIP = {"com.apple.Music"}          # the Apple Music adapter's, not ours
WAIT_FOR_ART_S = 6.0                # a new item's artwork loads a beat late

APPS = {
    "com.spotify.client": "Spotify",
    "com.tidal.desktop": "TIDAL",
    "com.google.Chrome": "Chrome",
    "com.apple.Safari": "Safari",
    "company.thebrowser.Browser": "Arc",
    "org.mozilla.firefox": "Firefox",
    "com.microsoft.edgemac": "Edge",
    "com.brave.Browser": "Brave",
    "com.amazon.music": "Amazon Music",
    "com.deezer.deezer-desktop": "Deezer",
    "org.videolan.vlc": "VLC",
    "com.apple.QuickTimePlayerX": "QuickTime",
    "com.apple.TV": "Apple TV",
    "com.apple.podcasts": "Podcasts",
    "com.anthropic.claudefordesktop": "Claude",
}


def binary():
    """Where media-control is, or None. launchd's PATH does not include
    Homebrew, so the usual places are tried by name."""
    found = shutil.which("media-control")
    if found:
        return found
    for p in CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def app_name(bundle: str) -> str:
    if bundle in APPS:
        return APPS[bundle]
    tail = bundle.rsplit(".", 1)[-1] if bundle else "?"
    return tail[:1].upper() + tail[1:]


def bundle_of(track_id: str) -> str:
    """'mac:<bundle>:<hash>' -> bundle, else ''."""
    parts = track_id.split(":", 2)
    return parts[1] if len(parts) == 3 and parts[0] == "mac" else ""


def _since(stamp) -> float:
    """media-control stamps elapsedTime with an ISO time; seconds since it."""
    try:
        t = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        return max(0.0, (datetime.now(timezone.utc) - t).total_seconds())
    except (TypeError, ValueError):
        return 0.0


class MacMediaSource(NowPlayingSource):
    name = "mac"

    def __init__(self, path: str | None = None):
        self.path = path or binary()
        if not self.path:
            raise FileNotFoundError(
                "media-control not installed: brew install media-control")
        self._first_seen = None    # (track key, monotonic) while still artless
        self._art_key = None
        self._art_url = None

    @staticmethod
    def available() -> bool:
        return binary() is not None

    def _read(self):
        proc = subprocess.run([self.path, "get"], capture_output=True,
                              text=True, timeout=8)
        if proc.returncode != 0:
            raise RuntimeError("media-control: "
                               f"{proc.stderr.strip()[:160] or proc.returncode}")
        out = proc.stdout.strip()
        if not out or out == "null":
            return None
        return json.loads(out)

    def _guess_art(self, key, title, artist, album):
        if key == self._art_key:
            return self._art_url
        clean = (album or "").removesuffix(" - Single").removesuffix(" - EP")
        url = None
        if artist and clean:
            url = _itunes_art(f"{artist} {clean}", "album")
        if not url and artist:
            url = _itunes_art(f"{artist} {title}", "song")
        if url:
            self._art_key, self._art_url = key, url
        return url

    def get_current(self):
        d = self._read()
        if not d:
            return None
        bundle = d.get("bundleIdentifier") or ""
        if bundle in SKIP or not d.get("playing"):
            return None
        title = (d.get("title") or "").strip()
        if not title:
            return None
        artist = (d.get("artist") or "").strip()
        album = (d.get("album") or "").strip()
        key = hashlib.sha1(f"{bundle}|{title}|{artist}|{album}".encode()).hexdigest()[:12]

        art = None
        data = d.get("artworkData")
        if data:
            mime = d.get("artworkMimeType") or "image/jpeg"
            art = f"data:{mime};base64,{data}"
            self._first_seen = None
        else:
            # Artwork tends to arrive a moment after the title. Give it a few
            # seconds before guessing from the title: for a browser tab a
            # guessed sleeve is worse than a short wait for the real thumbnail.
            if not self._first_seen or self._first_seen[0] != key:
                self._first_seen = (key, time.monotonic())
            if time.monotonic() - self._first_seen[1] >= WAIT_FOR_ART_S:
                art = self._guess_art(key, title, artist, album)

        progress = None
        elapsed = d.get("elapsedTime")
        if isinstance(elapsed, (int, float)):
            progress = int((elapsed + _since(d.get("timestamp"))) * 1000)
        duration = d.get("duration")
        duration_ms = (int(duration * 1000)
                       if isinstance(duration, (int, float)) and duration > 0 else None)
        if progress is not None and duration_ms:
            progress = min(progress, duration_ms)

        return NowPlaying(
            track_id=f"mac:{bundle}:{key}",
            title=title, artist=artist or "?", album=album or "?",
            art_url=art, progress_ms=progress, duration_ms=duration_ms,
            is_playing=True,
        )
