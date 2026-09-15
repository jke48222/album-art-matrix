"""The wall's own song library on made-up songs.

    .venv/bin/python -m pytest brain/tests/test_teach.py -q
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying import NowPlaying                                   # noqa: E402
from brain.nowplaying.teach import (Library, Teacher, fingerprint, RATE,   # noqa: E402
                                    MIN_SCORE)

# a seed no song uses: a song's own noise floor, drawn from the same seed,
# would come back shifted by a frame and vote for it (it did, in a test)
rng = np.random.default_rng(1000)


def song(seed: int, seconds: float = 30.0) -> np.ndarray:
    """A made-up song: notes of random pitch and length with harmonics and
    a little noise, which has peaks the way music has."""
    r = np.random.default_rng(seed)
    n = int(RATE * seconds)
    out = np.zeros(n)
    t = 0
    while t < n:
        dur = int(RATE * r.uniform(0.15, 0.6))
        f0 = r.uniform(110, 900)
        tt = np.arange(min(dur, n - t)) / RATE
        env = np.minimum(1.0, tt * 40) * np.exp(-tt * r.uniform(0.5, 3.0))
        note = sum(np.sin(2 * np.pi * f0 * k * tt + r.uniform(0, 6.3)) / k for k in (1, 2, 3, 4))
        out[t:t + tt.size] += note * env * r.uniform(0.2, 0.6)
        t += dur
    out += r.normal(0, 0.01, n)
    return np.clip(out * 32768 * 0.5, -32768, 32767).astype(np.int16)


def through_a_room(pcm: np.ndarray, noise_db: float = -30.0, gain: float = 0.5) -> np.ndarray:
    """A clip as a microphone across the room would hear it: quieter, a
    little smeared, and under noise."""
    x = pcm.astype(np.float64) * gain
    kernel = np.array([0.6, 0.3, 0.1])
    x = np.convolve(x, kernel, mode="same")
    x += rng.normal(0, 32768 * 10 ** (noise_db / 20.0), x.size)
    return np.clip(x, -32768, 32767).astype(np.int16)


def test_fingerprint_is_deterministic_and_dense_enough():
    a = song(1)
    h1, t1 = fingerprint(a)
    h2, t2 = fingerprint(a)
    assert h1.size == h2.size and (h1 == h2).all() and (t1 == t2).all()
    assert h1.size > 500                                  # a 30 s song has plenty


def test_a_clip_finds_its_song_with_the_right_offset(tmp_path):
    lib = Library(path=str(tmp_path))
    for seed in (1, 2, 3, 4, 5):
        lib.learn(song(seed), title=f"Song {seed}", artist="Someone", how="preview")
    assert lib.status()["songs"] == 5
    clip = song(3)[int(RATE * 10):int(RATE * 18)]         # 8 s from 10 s in
    m = lib.query(clip)
    assert m is not None and m.song["title"] == "Song 3"
    assert 9.5 <= m.offset_s <= 10.5
    assert m.score >= MIN_SCORE


def test_a_room_recording_still_matches(tmp_path):
    lib = Library(path=str(tmp_path))
    for seed in range(1, 9):
        lib.learn(song(seed), title=f"Song {seed}", artist="Someone", how="preview")
    clip = through_a_room(song(6)[int(RATE * 4):int(RATE * 12)])
    m = lib.query(clip)
    assert m is not None and m.song["title"] == "Song 6"
    assert 3.5 <= m.offset_s <= 4.5


def test_an_unknown_song_and_noise_do_not_match(tmp_path):
    lib = Library(path=str(tmp_path))
    for seed in range(1, 9):
        lib.learn(song(seed), title=f"Song {seed}", artist="Someone", how="preview")
    assert lib.query(song(77)[:int(RATE * 8)]) is None
    noise = (np.random.default_rng(2000).normal(0, 3000, int(RATE * 8))).astype(np.int16)
    assert lib.query(noise) is None
    assert lib.query(song(3)[:int(RATE * 1)]) is None      # too short to ask


def test_the_library_survives_a_restart_and_forgets(tmp_path):
    lib = Library(path=str(tmp_path))
    lib.learn(song(1), title="One", artist="A", album="LP", art_url="https://x/1.jpg", how="preview")
    lib.learn(song(2), title="Two", artist="B", how="ear")
    again = Library(path=str(tmp_path))
    assert again.status()["songs"] == 2
    m = again.query(song(2)[int(RATE * 5):int(RATE * 13)])
    assert m is not None and m.song["title"] == "Two" and m.song["how"] == ["ear"]
    assert again.forget(Library.song_id("Two", "B"))
    assert again.query(song(2)[int(RATE * 5):int(RATE * 13)]) is None
    m1 = again.query(song(1)[int(RATE * 5):int(RATE * 13)])
    assert m1 is not None and m1.song["album"] == "LP"
    again.clear()
    assert Library(path=str(tmp_path)).status()["songs"] == 0


def test_two_recordings_vouch_for_one_song(tmp_path):
    lib = Library(path=str(tmp_path))
    lib.learn(song(4), title="Four", artist="A", how="preview")
    lib.learn(through_a_room(song(4)[int(RATE * 8):int(RATE * 23)]), title="Four", artist="A", how="ear")
    assert lib.status()["songs"] == 1
    s = lib.songs[Library.song_id("Four", "A")]
    assert s["how"] == ["preview", "ear"]
    m = lib.query(through_a_room(song(4)[int(RATE * 12):int(RATE * 20)]))
    assert m is not None and m.song["title"] == "Four"


class FakeEar:
    def __init__(self):
        self.attempts = 0
        self.gate_open = True
        self._hit = None
        self._ring = [song(9)[i:i + 1600].tobytes() for i in range(0, RATE * 15, 1600)]


def now(title, artist, tid="mac:1"):
    return NowPlaying(track_id=tid, title=title, artist=artist, album="LP", art_url="https://x/a.jpg",
                      progress_ms=None, duration_ms=200_000, is_playing=True)


def test_the_teacher_learns_a_preview_after_the_ear_misses(tmp_path):
    lib = Library(path=str(tmp_path))
    ear = FakeEar()
    fetched = []
    def fetch(title, artist):
        fetched.append((title, artist))
        return song(9), {"title": title, "artist": artist, "album": "LP", "art_url": None, "duration_ms": 200_000}
    t = Teacher(lib, ear, by_ear=False, fetch=fetch)
    n = now("Tower of Roses", "MALI")
    t.observe(n, mono=100.0)
    ear.attempts = 2
    t.observe(n, mono=110.0)
    assert fetched == []                                    # two misses are not enough
    ear.attempts = 3
    t.observe(n, mono=120.0)
    import time as _t
    for _ in range(50):
        if lib.status()["songs"]:
            break
        _t.sleep(0.05)
    assert fetched == [("Tower of Roses", "MALI")]
    assert lib.has("Tower of Roses", "MALI", "preview")
    t.observe(n, mono=130.0)
    assert len(fetched) == 1                                # known now: not fetched again


def test_the_teacher_learns_the_room_after_fifteen_loud_seconds(tmp_path):
    lib = Library(path=str(tmp_path))
    ear = FakeEar()
    t = Teacher(lib, ear, by_ear=True, fetch=lambda *_: None)
    n = now("Nights", "Frank Ocean")
    t.observe(n, mono=100.0)
    t.observe(n, mono=110.0)
    assert not lib.has("Nights", "Frank Ocean")
    t.observe(n, mono=116.0)
    import time as _t
    for _ in range(50):
        if lib.status()["songs"]:
            break
        _t.sleep(0.05)
    assert lib.has("Nights", "Frank Ocean", "ear")
    m = lib.query(song(9)[int(RATE * 3):int(RATE * 11)])   # the room's recording was song 9
    assert m is not None and m.song["title"] == "Nights"


def test_the_ear_itself_is_never_taught(tmp_path):
    lib = Library(path=str(tmp_path))
    ear = FakeEar()
    ear.attempts = 10
    t = Teacher(lib, ear, by_ear=True, fetch=lambda *_: (song(1), {}))
    t.observe(now("X", "Y", tid="ears:abc"), mono=100.0)
    t.observe(now("X", "Y", tid="ears:abc"), mono=130.0)
    assert lib.status()["songs"] == 0


def test_a_preview_must_match_the_title_not_just_the_artist():
    from brain.nowplaying.teach import pick_preview
    results = [
        {"wrapperType": "track", "trackName": "White Ferrari", "artistName": "Frank Ocean", "previewUrl": "u1"},
        {"wrapperType": "track", "trackName": "Nights", "artistName": "Frank Ocean", "previewUrl": "u2"},
        {"wrapperType": "track", "trackName": "Nights (Live)", "artistName": "Frank Ocean", "previewUrl": "u3"},
        {"wrapperType": "collection", "collectionName": "Blonde", "artistName": "Frank Ocean"},
    ]
    assert pick_preview(results, "Nights", "Frank Ocean")["previewUrl"] == "u2"
    assert pick_preview(results[:1], "Nights", "Frank Ocean") is None            # White Ferrari is not Nights
    assert pick_preview(results, "Pink + White", "Frank Ocean") is None
    assert pick_preview(results, "Nights", "Kelela & PinkPantheress") is None
    assert pick_preview(results, "Nights", "Frank Ocean, Someone")["previewUrl"] == "u2"
