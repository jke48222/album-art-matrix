"""Synthetic room clips exercise timing across arbitrary capture boundaries."""
import numpy as np
import pytest

from brain.gestures import GestureDetector, RATE


def pcm(x):
    return (np.clip(x, -1, 1) * 32767).astype('<i2').tobytes()


def burst(length=.035, seed=1):
    t = np.arange(int(length * RATE)) / RATE
    return np.random.default_rng(seed).normal(0, .35, len(t)) * np.exp(-t / .007)


def knocks(times, duration=4):
    x = np.random.default_rng(31).normal(0, .00005, RATE * duration)
    for i, at in enumerate(times):
        b = burst(seed=i+1)
        index = int(at * RATE)
        x[index:index+len(b)] += b
    return x


def feed(x, **options):
    detector = GestureDetector(log=lambda _: None)
    events = []
    data = pcm(x)
    for i in range(0, len(data), 3200):
        events.extend(detector.feed(data[i:i+3200], **options))
    return events


def test_two_knocks_toggle():
    events = feed(knocks([1.2, 1.65]), whistle=False)
    assert len(events) == 1
    assert events[0]["gesture"] == "knock" and events[0]["action"] == "toggle"
    assert events[0]["interval_ms"] == 450


@pytest.mark.parametrize('times', [[1.2], [1.2, 1.3], [1.2, 2.2]])
def test_bad_intervals_do_not_toggle(times):
    assert feed(knocks(times), whistle=False) == []


def test_debounce():
    assert len(feed(knocks([1.2, 1.65, 2.0, 2.45]), whistle=False)) == 1


@pytest.mark.parametrize('rising, action', [(True, 'on'), (False, 'off')])
def test_sine_sweep(rising, action):
    t = np.arange(int(RATE * .7)) / RATE
    start, slope = (1300, 350) if rising else (1600, -350)
    tone = .2 * np.sin(2 * np.pi * (start * t + .5 * slope * t*t))
    x = np.concatenate((np.zeros(RATE), tone, np.zeros(RATE)))
    events = feed(x, knock=False)
    assert len(events) == 1 and events[0]['action'] == action
    assert 1.3 <= events[0]['at'] < 1.5


def test_short_tone_and_noise_do_not_whistle():
    t = np.arange(int(RATE * .15)) / RATE
    x = np.concatenate((np.zeros(RATE), .2 * np.sin(2 * np.pi * 1500 * t),
                        np.random.default_rng(5).normal(0, .1, RATE)))
    assert feed(x, knock=False) == []


def test_drum_loop_does_not_toggle():
    x = np.zeros(RATE * 8)
    for i in range(16):
        t = np.arange(int(.18 * RATE)) / RATE
        kick = .4 * np.sin(2 * np.pi * 85 * t) * np.exp(-t / .045)
        snare = np.random.default_rng(i).normal(0, .2, len(t)) * np.exp(-t / .035)
        sound = kick if i % 2 == 0 else snare
        at = int(i * .5 * RATE)
        x[at:at+len(sound)] += sound
    assert feed(x, music_db=-18) == []


def test_narrow_clicks_are_not_knocks():
    x = np.zeros(RATE * 4)
    t = np.arange(int(.035 * RATE)) / RATE
    b = .4 * np.sin(2 * np.pi * 220 * t) * np.exp(-t / .01)
    for at in [1.2, 1.6]:
        i = int(at * RATE)
        x[i:i+len(b)] = b
    assert feed(x, whistle=False) == []


def test_off_remembers_face_across_restart(tmp_path, monkeypatch):
    from brain import control
    monkeypatch.setattr(control, 'STATE_PATH', str(tmp_path / 'control.json'))
    monkeypatch.setattr(control, 'JOURNAL_PATH', str(tmp_path / 'journal.jsonl'))
    ctrl = control.ControlState(seed={'mode': 'clock'})
    ctrl.gesture_power('toggle')
    assert ctrl.get()['mode'] == 'off' and ctrl.get()['knock_ret'] == 'clock'
    restored = control.ControlState()
    restored.gesture_power('on')
    assert restored.get()['mode'] == 'clock'
    restored.gesture_power('on')
    assert restored.get()['mode'] == 'clock'
