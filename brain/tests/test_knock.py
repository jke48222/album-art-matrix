"""The knock and whistle detectors on made-up sound.

    .venv/bin/python -m pytest brain/tests/test_knock.py -q
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying.knock import (KnockDetector, WhistleDetector, KnockEar,   # noqa: E402
                                    RATE, PAIR_MAX_S)

CHUNK = int(RATE * 0.1)
rng = np.random.default_rng(7)


def noise(seconds: float, dbfs: float) -> np.ndarray:
    amp = 32768.0 * 10 ** (dbfs / 20.0)
    return rng.normal(0.0, amp / 1.0, int(RATE * seconds))


def knock(sound: np.ndarray, at_s: float, dbfs: float = -8.0, ms: float = 30.0):
    """A knock: a burst of noise with a sharp attack and a fast decay, plus
    a low thump, so it is broadband the way wood is."""
    n = int(RATE * ms / 1000.0)
    i = int(RATE * at_s)
    env = np.exp(-np.linspace(0, 6, n))
    amp = 32768.0 * 10 ** (dbfs / 20.0)
    burst = rng.normal(0.0, 1.0, n) * env * amp * 0.7
    thump = np.sin(2 * np.pi * 120.0 * np.arange(n) / RATE) * env * amp * 0.7
    sound[i:i + n] += burst + thump
    return sound


def feed(det, sound: np.ndarray, gate_open=False, start_t=100.0):
    pcm = np.clip(sound, -32768, 32767).astype(np.int16)
    t = start_t
    for i in range(0, pcm.size - CHUNK + 1, CHUNK):
        t += 0.1
        if isinstance(det, KnockDetector):
            det.feed(pcm[i:i + CHUNK].tobytes(), gate_open=gate_open, now=t)
        else:
            det.feed(pcm[i:i + CHUNK].tobytes(), now=t)


def test_two_knocks_alone_toggle():
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    s = knock(knock(noise(4.0, -50.0), 1.5), 1.9)
    feed(det, s)
    assert len(hits) == 1
    assert 350 <= hits[0]["gap_ms"] <= 450
    assert det.count_candidates == 2


def test_one_knock_does_nothing():
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    feed(det, knock(noise(3.0, -50.0), 1.5))
    assert hits == [] and det.count_candidates == 1


def test_knocks_too_far_apart_do_nothing():
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    feed(det, knock(knock(noise(5.0, -50.0), 1.0), 1.0 + PAIR_MAX_S + 0.4))
    assert hits == []


def test_three_knocks_are_not_a_pair():
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    feed(det, knock(knock(knock(noise(5.0, -50.0), 1.0), 1.4), 1.8))
    assert hits == []


def test_a_drum_loop_is_not_knocking():
    """Hits every half second, for seconds: pairs everywhere, none alone."""
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    s = noise(8.0, -40.0)
    for k in range(14):
        knock(s, 0.8 + 0.5 * k, dbfs=-12.0)
    feed(det, s, gate_open=True)
    assert hits == []


def test_a_slow_swell_is_not_a_knock():
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    s = noise(4.0, -50.0)
    n = int(RATE * 0.4)
    ramp = np.linspace(0, 1, n) * 32768.0 * 10 ** (-10 / 20.0)
    s[RATE:RATE + n] += rng.normal(0.0, 1.0, n) * ramp
    s[2 * RATE:2 * RATE + n] += rng.normal(0.0, 1.0, n) * ramp
    feed(det, s)
    assert det.count_candidates == 0 and hits == []


def test_a_plucked_note_is_not_broadband_enough():
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    s = noise(4.0, -50.0)
    for at in (1.0, 1.4):
        i = int(RATE * at)
        n = int(RATE * 0.03)
        env = np.exp(-np.linspace(0, 6, n))
        s[i:i + n] += np.sin(2 * np.pi * 1000.0 * np.arange(n) / RATE) * env * 32768.0 * 0.4
    feed(det, s)
    assert hits == []


def test_knocks_over_music_need_more():
    """With the gate open the bar is higher: a soft tap fails, a real knock passes."""
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    # a knock's first 10 ms sit 7 to 9 dB under its nominal level (the decay
    # and the clipping), so these land at roughly 19 and 30 dB over a room at
    # -40; the bar over music is the 20 of the knob plus 6
    s = knock(knock(noise(4.0, -40.0), 1.5, dbfs=-14.0), 1.9, dbfs=-14.0)
    feed(det, s, gate_open=True)
    assert hits == []
    hits = []
    det = KnockDetector(on_double=hits.append, log=lambda s: None)
    s = knock(knock(noise(4.0, -40.0), 1.5, dbfs=-2.0), 1.9, dbfs=-2.0)
    feed(det, s, gate_open=True)
    assert len(hits) == 1


def sweep(seconds: float, f0: float, f1: float, dbfs: float = -20.0) -> np.ndarray:
    n = int(RATE * seconds)
    t = np.arange(n) / RATE
    f = f0 + (f1 - f0) * t / seconds
    phase = 2 * np.pi * np.cumsum(f) / RATE
    return np.sin(phase) * 32768.0 * 10 ** (dbfs / 20.0)


def test_rising_whistle_is_up():
    got = []
    det = WhistleDetector(on_whistle=lambda k, i: got.append(k), log=lambda s: None)
    s = noise(3.0, -55.0)
    s[RATE:RATE + int(RATE * 0.6)] += sweep(0.6, 1100.0, 1500.0)
    feed(det, s)
    assert got == ["up"]


def test_falling_whistle_is_down():
    got = []
    det = WhistleDetector(on_whistle=lambda k, i: got.append(k), log=lambda s: None)
    s = noise(3.0, -55.0)
    s[RATE:RATE + int(RATE * 0.6)] += sweep(0.6, 1600.0, 1150.0)
    feed(det, s)
    assert got == ["down"]


def test_a_short_or_flat_whistle_does_nothing():
    got = []
    det = WhistleDetector(on_whistle=lambda k, i: got.append(k), log=lambda s: None)
    s = noise(3.0, -55.0)
    s[RATE:RATE + int(RATE * 0.15)] += sweep(0.15, 1100.0, 1500.0)     # too short
    s[2 * RATE:2 * RATE + int(RATE * 0.6)] += sweep(0.6, 1300.0, 1310.0)  # flat
    feed(det, s)
    assert got == []


def test_noise_and_music_do_not_whistle():
    got = []
    det = WhistleDetector(on_whistle=lambda k, i: got.append(k), log=lambda s: None)
    s = noise(3.0, -25.0)
    t = np.arange(RATE * 3) / RATE
    for f in (220.0, 330.0, 440.0, 660.0, 880.0):                      # a chord
        s += np.sin(2 * np.pi * f * t) * 32768.0 * 0.05
    feed(det, s)
    assert got == []


def test_whistle_over_a_song_still_counts():
    got = []
    det = WhistleDetector(on_whistle=lambda k, i: got.append(k), log=lambda s: None)
    s = noise(3.0, -35.0)
    t = np.arange(RATE * 3) / RATE
    for f in (220.0, 330.0, 440.0):
        s += np.sin(2 * np.pi * f * t) * 32768.0 * 0.03
    s[RATE:RATE + int(RATE * 0.7)] += sweep(0.7, 1200.0, 1700.0, dbfs=-14.0)
    feed(det, s)
    assert got == ["up"]


class FakeCtrl:
    def __init__(self):
        self.mode = "art"
        self.calls = []

    def knock_toggle(self, why, want=None):
        self.calls.append((why, want))
        if want == "on" or (want is None and self.mode == "off"):
            self.mode = "art"
            return "on"
        self.mode = "off"
        return "off"


def test_the_ear_side_wires_both_to_the_wall():
    ctrl = FakeCtrl()
    ear = KnockEar(ctrl, log=lambda s: None)
    s = knock(knock(noise(4.0, -50.0), 1.5), 1.9)
    pcm = np.clip(s, -32768, 32767).astype(np.int16)
    t = 100.0
    for i in range(0, pcm.size - CHUNK + 1, CHUNK):
        t += 0.1
        ear.feed(pcm[i:i + CHUNK].tobytes(), gate_open=False, now=t)
    assert ctrl.calls == [("two knocks", None)] and ctrl.mode == "off"
    ear.configure(knock=False)
    ear.feed(pcm[:CHUNK].tobytes(), gate_open=False, now=t + 0.1)
    assert ear.status()["knock"] is False and ear.status()["toggles"] == 1
