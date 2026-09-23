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

ONE CLOCK PER SONG. The faces run on the song's clock (lyrics, the spin,
the progress bar), and more than one source can describe the same song: the
phone with its exact position, the account's view with no position at all,
the ears with a guess (where Shazam placed the clip, plus the time since).
Left to "first answer wins" the clock changed hands every time the phone
went quiet for a moment, and every hand-over was a jump of a few seconds
back or forward. Worse, a player's own "paused" lost to any outsider still
saying "playing", so lyrics ran on after the pause button. The chain now
remembers the last player that knew the clock and carries that clock while
lesser sources fill in, and a player's paused verdict silences outside
claims about the same song until something is actually heard again.
"""
import time
from dataclasses import dataclass, replace
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
    # How good the clock is. "exact" is a player reporting its own position
    # (the phone's push, the Mac's player, Spotify's API). "approx" is a
    # guess from outside the player: the ears place the clip Shazam named
    # and let the clock run from there.
    clock: str = "exact"
    # When this answer's evidence was last fresh (time.monotonic()): the
    # moment the phone pushed it, the moment the ears last named the song.
    # None means live, as of this poll. It is how a stale "playing" is kept
    # from outliving a player's "paused", and how a hearing newer than a
    # paused push is allowed to say the music is back.
    heard_at: Optional[float] = None


class NowPlayingSource:
    """One adapter. get_current() returns a NowPlaying, or None when this
    source has no answer (not configured, nothing playing, service down)."""
    name = "base"

    def get_current(self) -> Optional[NowPlaying]:
        raise NotImplementedError


CLOCK_HOLD_S = 900.0   # a player's clock is carried this long after it goes quiet
PAUSE_HOLD_S = 900.0   # a player's "paused" outranks outside claims this long
DRIFT_S = 4.0          # an outside clock this far off, heard anew, means a seek
STALE_S = 7.0          # a player's report this far BEHIND the carried clock is a seek;
                       # nearer than that it is only a stale snapshot (the Mac's
                       # reporter refreshes every five seconds or so)
LEAD_MS = 150          # a report this far ahead of the carried clock is fresher: take it


def _key(now: NowPlaying):
    """The same song under any adapter's spelling: first artist and title,
    folded the way the shelf folds them."""
    from ..shelf import fold, fold_artist      # shelf imports nothing of ours
    return (fold_artist(now.artist or ""), fold(now.title or ""))


class SourceChain(NowPlayingSource):
    """First adapter with an answer wins, with refinements. An answer that
    says something is PLAYING beats an earlier one that only says paused:
    a Mac left paused on a song keeps its sleeve up (that is the Mac
    adapter's choice), but it must not outrank the record player the wall
    can hear. Two exceptions, both about the SAME song: a player's own
    "paused" beats an outsider's stale "playing", and a player's clock is
    carried while an outsider stands in for it. Adapter errors are logged,
    not fatal."""
    name = "chain"

    def __init__(self, sources, now=time.monotonic):
        self.sources = list(sources)
        self._now = now
        self._passed = None          # the last sleeveless answer, so it is logged once
        self._held = None            # (key, NowPlaying, at): last exact clock from a player
        self._paused = None          # (key, NowPlaying, at): last exact "paused" from a player
        self._via = None             # which source answered last, logged on change

    def _say(self, src):
        name = src.name if src is not None else "nobody"
        if name != self._via:
            self._via = name
            print(f"[nowplaying] via {name}")

    def get_current(self):
        # The first PLAYING answer with a sleeve wins. A playing answer with
        # no sleeve (a video in a browser tab, a song whose art could not be
        # found) is not a song the wall can wear: it is passed over, and the
        # wall stays quiet if nothing else is on. Paused answers come last;
        # main.py decides whether a paused song is the one already up or a
        # stranger.
        paused, paused_src = None, None
        for src in self.sources:
            try:
                now = src.get_current()
            except Exception as exc:
                print(f"[nowplaying] {src.name}: {exc}")
                continue
            # the clock is read AFTER the source answers: asking the Mac
            # takes a second or two, and a carried position stamped before
            # the wait was that much behind a fresh one, so the clock
            # stepped back by the wait on every other poll
            t = self._now()
            if now is None:
                continue
            if not now.is_playing:
                if paused is None:
                    paused, paused_src = now, src
                    if now.progress_ms is not None and now.clock == "exact":
                        # stamped when the player said so, not when the
                        # chain saw it: a paused push is held for a while
                        said = now.heard_at if now.heard_at is not None else t
                        self._paused = (_key(now), now, said)
                        self._held = (_key(now), now, said)
                continue
            if not now.art_url:
                if now.track_id != self._passed:
                    self._passed = now.track_id
                    print(f"[nowplaying] {src.name}: {now.title!r} has no sleeve; passed over")
                continue
            key = _key(now)
            if paused is not None and _key(paused) == key and now.clock == "exact":
                # An earlier, authoritative player has explicitly paused this
                # song. A second player's stale exact position cannot resume it.
                continue
            if now.progress_ms is not None and now.clock == "exact":
                # a player that knows where it is: its clock is the song's.
                # Its reports are still snapshots, each anywhere from fresh
                # to a few seconds stale, and taken as they come the clock
                # ran forward and back by that much on every poll. So the
                # clock only ratchets: a report ahead of the carried clock
                # is fresher and taken, one a little behind is a stale copy
                # and ignored, one far behind is a seek and taken.
                held = self._held
                if held is not None and held[0] == key and t - held[2] < CLOCK_HOLD_S \
                        and held[1].is_playing:
                    carried = held[1].progress_ms + int((t - held[2]) * 1000)
                    if now.duration_ms:
                        carried = min(carried, now.duration_ms)
                    behind = carried - now.progress_ms
                    if -LEAD_MS <= behind < STALE_S * 1000:
                        now = replace(now, progress_ms=carried)
                self._held = (key, now, t)
                if self._paused is not None and self._paused[0] == key:
                    self._paused = None
                self._say(src)
                return now
            pz = self._paused
            if pz is not None and pz[0] == key and t - pz[2] < PAUSE_HOLD_S \
                    and not (now.heard_at is not None and now.heard_at > pz[2]):
                # the player said this song is paused and nothing has been
                # heard since: an outsider's "playing" is the old news
                continue
            held = self._held
            if held is not None and held[0] == key and t - held[2] < CLOCK_HOLD_S:
                hkey, hnow, hat = held
                if not hnow.is_playing and now.heard_at is not None and now.heard_at > hat:
                    out = replace(hnow, progress_ms=now.progress_ms if now.progress_ms is not None else hnow.progress_ms,
                                  is_playing=True, clock=now.clock, heard_at=now.heard_at)
                    self._held = (key, out, t)
                    self._say(src)
                    return out
                carried = hnow.progress_ms + int((t - hat) * 1000)
                if hnow.duration_ms:
                    carried = min(carried, hnow.duration_ms)
                fresh = now.heard_at is not None and now.heard_at > hat
                if fresh and now.progress_ms is not None \
                        and abs(now.progress_ms - carried) > DRIFT_S * 1000:
                    # heard anew somewhere else in the song: the record was
                    # moved. Follow the ears, but keep the player's identity
                    # so the sleeve does not re-show as a stranger.
                    out = replace(hnow, progress_ms=now.progress_ms, is_playing=True,
                                  clock="approx", heard_at=now.heard_at)
                    self._held = (key, out, t)
                    self._say(src)
                    return out
                # the player's own clock, run forward, under the player's name
                self._say(src)
                return replace(hnow, progress_ms=carried, is_playing=True)
            self._say(src)
            return now
        self._say(None if paused is None else paused_src)
        return paused
