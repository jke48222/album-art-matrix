"""Now-playing sources behind one interface (research 19.3).

Four adapters planned, ranked by robustness:
  1. acoustid    — Chromaprint -> AcoustID -> MusicBrainz -> Cover Art Archive.
                   The bulletproof floor: hears the room. Stage S3.
  2. spotify     — OAuth /me/player/currently-playing. Implemented (S1).
  3. lastfm      — scrobble fallback across many players. Stage S3.
  4. localplayer — MPRIS/playerctl. Stage S3.

When Spotify changes the rules again, you change one file.
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
