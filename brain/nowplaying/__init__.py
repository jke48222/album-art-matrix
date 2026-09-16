"""Now-playing sources behind one interface (research 19.3).

The chain, first answer wins (config [nowplaying] adapters):
  phone          what the app posts straight to the wall (pushed.py)
  applemusic     Music.app, then anything else the Mac plays (macmedia.py:
                 Spotify's app, TIDAL, a browser on YouTube Music...), then
                 the account's view across devices (applemusic_account.py)
  spotify        the Web API, any device the account plays on (spotify.py)
  lastfm         one account Spotify, Tidal and Deezer report to (lastfm.py)
  listenbrainz   the open equivalent; reading it needs no key (listenbrainz.py)
  ears           the wall's own microphone, named by Shazam (ears.py)

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
    isrc: Optional[str] = None


class NowPlayingSource:
    """One adapter. get_current() returns a NowPlaying, or None when this
    source has no answer (not configured, nothing playing, service down)."""
    name = "base"

    def get_current(self) -> Optional[NowPlaying]:
        raise NotImplementedError


class SourceChain(NowPlayingSource):
    """First adapter with an answer wins, with one refinement: an answer
    that says something is PLAYING beats an earlier one that only says
    paused. A Mac left paused on a song keeps its sleeve up (that is the
    Mac adapter's choice), but it must not outrank the record player the
    wall can hear; a Mac actually playing, with its progress bar, still
    comes first. Adapter errors are logged, not fatal."""
    name = "chain"

    def __init__(self, sources):
        self.sources = list(sources)
        self._passed = None          # the last sleeveless answer, so it is logged once

    def get_current(self):
        # The first PLAYING answer with a sleeve wins. A playing answer with
        # no sleeve (a video in a browser tab, a song whose art could not be
        # found) is not a song the wall can wear: it is passed over, and the
        # wall stays quiet if nothing else is on. Paused answers come last;
        # main.py decides whether a paused song is the one already up or a
        # stranger.
        paused = None
        for src in self.sources:
            try:
                now = src.get_current()
            except Exception as exc:
                print(f"[nowplaying] {src.name}: {exc}")
                continue
            if now is None:
                continue
            if now.is_playing:
                if now.art_url:
                    return now
                if now.track_id != self._passed:
                    self._passed = now.track_id
                    print(f"[nowplaying] {src.name}: {now.title!r} has no sleeve; passed over")
            elif paused is None:
                paused = now
        return paused
