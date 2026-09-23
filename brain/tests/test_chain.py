"""One clock per song.

The lyrics ran on after the pause button, and lines jumped back and forth
while a song played: the chain handed the song's clock to whichever source
answered first on each poll, and they did not agree. These pin the rules
that stopped it.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying import NowPlaying, SourceChain      # noqa: E402


class Src:
    def __init__(self, name, answer=None):
        self.name = name
        self.answer = answer

    def get_current(self):
        return self.answer


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def song(track_id, title="Constantly", artist="Tiffany Day & slayr", **kw):
    base = dict(track_id=track_id, title=title, artist=artist, album="Constantly - Single",
                art_url="https://art/x.jpg", progress_ms=30_000, duration_ms=200_000,
                is_playing=True)
    base.update(kw)
    return NowPlaying(**base)


def test_the_player_wins_and_its_clock_is_kept():
    clk = Clock()
    phone = Src("phone", song("catalog:1"))
    ears = Src("ears", song("shazam:1", progress_ms=27_000, clock="approx", heard_at=990.0))
    chain = SourceChain([phone, ears], now=clk)
    assert chain.get_current().track_id == "catalog:1"

    phone.answer = None                       # the phone's push expired
    clk.t += 10.0
    out = chain.get_current()
    assert out.track_id == "catalog:1"        # still the player's song, not a stranger
    assert out.progress_ms == 40_000          # the player's clock, run forward
    assert out.is_playing


def test_a_stranger_from_the_ears_is_taken_as_it_is():
    clk = Clock()
    phone = Src("phone", song("catalog:1"))
    ears = Src("ears", song("shazam:9", title="Other Song", artist="Someone Else",
                            progress_ms=5_000, clock="approx", heard_at=999.0))
    chain = SourceChain([phone, ears], now=clk)
    chain.get_current()
    phone.answer = None
    out = chain.get_current()
    assert out.track_id == "shazam:9" and out.progress_ms == 5_000


def test_paused_on_the_phone_means_paused_even_if_the_ears_remember_it():
    clk = Clock()
    phone = Src("phone", song("catalog:1"))
    ears = Src("ears", song("shazam:1", progress_ms=31_000, clock="approx", heard_at=999.0))
    chain = SourceChain([phone, ears], now=clk)
    chain.get_current()

    clk.t += 5.0
    phone.answer = song("catalog:1", progress_ms=35_000, is_playing=False)
    out = chain.get_current()
    assert out.track_id == "catalog:1" and not out.is_playing

    clk.t += 60.0                             # the phone's push has expired
    phone.answer = None
    out = chain.get_current()                 # the ears' hit is older than the pause
    assert out is None or not out.is_playing


def test_music_heard_after_the_pause_plays_again():
    clk = Clock()
    # the phone pushed "paused" at 1000 and the push is still held
    phone = Src("phone", song("catalog:1", is_playing=False, heard_at=1000.0))
    ears = Src("ears", song("shazam:1", progress_ms=31_000, clock="approx", heard_at=990.0))
    chain = SourceChain([phone, ears], now=clk)
    assert not chain.get_current().is_playing

    clk.t += 30.0
    ears.answer = song("shazam:1", progress_ms=61_000, clock="approx", heard_at=clk.t - 1)
    out = chain.get_current()                 # heard anew: someone pressed play
    assert out.is_playing and out.progress_ms == 61_000


def test_a_seek_heard_by_the_ears_is_followed_under_the_players_name():
    clk = Clock()
    phone = Src("phone", song("catalog:1"))
    ears = Src("ears", None)
    chain = SourceChain([phone, ears], now=clk)
    chain.get_current()

    phone.answer = None
    clk.t += 10.0
    ears.answer = song("shazam:1", progress_ms=41_000, clock="approx", heard_at=clk.t - 1)
    out = chain.get_current()                 # one second off: the carried clock stands
    assert out.track_id == "catalog:1" and out.progress_ms == 40_000

    clk.t += 10.0
    ears.answer = song("shazam:1", progress_ms=120_000, clock="approx", heard_at=clk.t - 1)
    out = chain.get_current()                 # a minute off: the record was moved
    assert out.track_id == "catalog:1" and out.progress_ms == 120_000


def test_an_earlier_source_without_a_clock_still_outranks_a_later_one_with():
    clk = Clock()
    account = Src("applemusic", song("account:1", progress_ms=None))
    spotify = Src("spotify", song("spotify:2", title="Another", artist="Band"))
    chain = SourceChain([account, spotify], now=clk)
    assert chain.get_current().track_id == "account:1"


def test_a_stale_playing_without_a_clock_is_silenced_by_the_players_pause():
    clk = Clock()
    phone = Src("phone", song("catalog:1", progress_ms=50_000, is_playing=False))
    account = Src("applemusic", song("account:1", progress_ms=None))   # lags: still "playing"
    chain = SourceChain([phone, account], now=clk)
    out = chain.get_current()
    assert out.track_id == "catalog:1" and not out.is_playing


def test_a_players_stale_snapshot_does_not_move_the_clock_back():
    clk = Clock()
    mac = Src("applemusic", song("applemusic:1", progress_ms=30_000))
    chain = SourceChain([mac], now=clk)
    assert chain.get_current().progress_ms == 30_000

    clk.t += 5.0
    mac.answer = song("applemusic:1", progress_ms=29_000)      # a six-second-old snapshot
    assert chain.get_current().progress_ms == 35_000           # the carried clock stands

    clk.t += 1.0
    mac.answer = song("applemusic:1", progress_ms=36_400)      # fresher than carried: taken
    assert chain.get_current().progress_ms == 36_400

    clk.t += 4.0
    mac.answer = song("applemusic:1", progress_ms=12_000)      # far behind: a seek, taken
    assert chain.get_current().progress_ms == 12_000

    clk.t += 1.0
    mac.answer = song("applemusic:1", progress_ms=20_000, is_playing=False)   # pause: as reported
    out = chain.get_current()
    assert not out.is_playing and out.progress_ms == 20_000
