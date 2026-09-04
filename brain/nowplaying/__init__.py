"""Now-playing sources behind one interface (research 19.3).

The chain, first answer wins (config [nowplaying] adapters):
  phone          what the app posts straight to the wall (pushed.py)
  applemusic     Music.app, then anything else the Mac plays (macmedia.py:
                 Spotify's app, TIDAL, a browser on YouTube Music...), then
                 the account's view across devices (applemusic_account.py)
  spotify        the Web API, any device the account plays on (spotify.py)
  lastfm         one account Spotify, Tidal and Deezer report to (lastfm.py)
  listenbrainz   the open equivalent; reading it needs no key (listenbrainz.py)
  acoustid       the wall's own microphone, for anything out loud (acoustid.py)

When a service changes the rules again, you change one file.
"""
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class NowPlaying:
    track_id: str            # adapter-prefixed stable id, e.g. "spotify:4uLU6..."
    title: str
    artist: str
    album: str
    art_url: Optional[str]   # highest-res cover art available
    progress_ms: Optional[int]
    duration_ms: Optional[int]
    is_playing: bool


class NowPlayingSource:
    """One adapter. get_current() returns a NowPlaying, or None when this
    source has no answer (not configured, nothing playing, service down)."""
    name = "base"

    def get_current(self) -> Optional[NowPlaying]:
        raise NotImplementedError


class SourceChain(NowPlayingSource):
    """First adapter with an answer wins. Adapter errors are logged, not fatal."""
    name = "chain"

    def __init__(self, sources):
        self.sources = list(sources)

    def get_current(self):
        for src in self.sources:
            try:
                now = src.get_current()
            except Exception as exc:
                print(f"[nowplaying] {src.name}: {exc}")
                continue
            if now is not None:
                return now
        return None
