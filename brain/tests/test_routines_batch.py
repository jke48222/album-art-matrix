"""R01–R05: real schedule, command and renderer regression checks."""
import base64
from datetime import date
import time

import numpy as np
import pytest

from brain.control import ControlState
from brain.routines import daily_at, next_daily, solar_status
from brain.sun import sun_times, sun_factor
from brain.art.text_modes import Clock, Countdown
from brain.tests.test_control import api


@pytest.fixture
def atlanta(monkeypatch):
    monkeypatch.setenv("TZ", "America/New_York")
    time.tzset()
    yield
    monkeypatch.undo()
    time.tzset()


@pytest.fixture
def clocks(monkeypatch):
    value = {"wall": 1790163000.0, "mono": 1000.0}
    monkeypatch.setattr(time, "time", lambda: value["wall"])
    monkeypatch.setattr(time, "monotonic", lambda: value["mono"])
    return value


def step(ctrl, clock, seconds):
    clock["wall"] += seconds
    clock["mono"] += seconds
    return ctrl.tick_routines()


@pytest.mark.parametrize("value", [None, {}, True, "tomorrow", float("nan"), float("inf"), -1, 181])
@pytest.mark.parametrize("key", ["timer_min", "sleep_fade_min"])
def test_bad_duration_cannot_cancel_an_existing_routine(value, key, clocks):
    ctrl = ControlState(); ctrl.apply({key: 10})
    before = ctrl.timer if key == "timer_min" else ctrl.sleep
    assert key in ctrl.apply({key: value})
    assert (ctrl.timer if key == "timer_min" else ctrl.sleep) is before


@pytest.mark.parametrize("key", ["lat", "lon", "sun_night", "brightness", "wake_fade_min"])
@pytest.mark.parametrize("value", [None, "bad", float("nan"), float("inf")])
def test_invalid_numbers_are_rejected_without_poisoning_render_state(key, value):
    ctrl = ControlState(); before = ctrl.get()[key]
    assert key in ctrl.apply({key: value})
    assert ctrl.get()[key] == before


def test_unknown_location_stays_unknown_across_restart():
    ctrl = ControlState(); ctrl.apply({"mode": "clock"})
    reloaded = ControlState()
    assert reloaded.get()["lat"] == 999 and reloaded.get()["lon"] == 999
    reloaded.apply({"sun": "on"})
    assert reloaded.public_state()["sun_phase"] == "location"


def test_timer_ceil_seconds_does_not_show_zero_while_running(clocks):
    ctrl = ControlState(); ctrl.apply({"timer_min": 1})
    state = step(ctrl, clocks, 59.8)
    assert state["timer_remaining_s"] == 1 and not state["timer_ringing"]
    state = step(ctrl, clocks, .2)
    assert state["timer_remaining_s"] == 0 and state["timer_ringing"]
    assert state["timer_kind"] == "countdown"


@pytest.mark.parametrize("prior", ["clock", "frame", "clip", "ambient", "off"])
def test_timer_cancel_and_completion_restore_original_face(prior, clocks):
    ctrl = ControlState(); ctrl.apply({"mode": prior}); ctrl.apply({"timer_min": 1})
    ctrl.apply({"timer_min": 2})
    assert ctrl.timer["ret"] == prior
    ctrl.apply({"timer_min": 0})
    assert ctrl.get()["mode"] == prior and ctrl.timer is None
    ctrl.apply({"timer_min": 1}); step(ctrl, clocks, 241)
    assert ctrl.get()["mode"] == prior and ctrl.timer is None


def test_selecting_another_face_clears_hidden_timer(clocks):
    ctrl = ControlState(); ctrl.apply({"timer_min": 1}); ctrl.apply({"mode": "ambient"})
    assert ctrl.timer is None and ctrl.public_state()["timer_state"] == "idle"


def test_sleep_uses_monotonic_clock_and_preserves_brightness(clocks):
    ctrl = ControlState(); ctrl.apply({"mode": "clock", "brightness": .8, "sleep_fade_min": 10})
    state = step(ctrl, clocks, 300)
    assert state["effective_brightness"] == pytest.approx(.4)
    clocks["wall"] += 3600
    assert ctrl.tick_routines()["sleep_remaining_s"] == 300
    ctrl.apply({"sleep_fade_min": 0})
    state = ctrl.tick_routines()
    assert state["sleep_state"] == "cancelled" and state["effective_brightness"] == .8
    assert ctrl.get()["mode"] == "clock"
    ctrl.apply({"sleep_fade_min": 1}); state = step(ctrl, clocks, 61)
    assert state["sleep_state"] == "completed" and state["effective_brightness"] == 0
    assert ctrl.get()["mode"] == "off" and ctrl.get()["brightness"] == .8


def test_solar_evening_uses_location_date_after_utc_midnight():
    # 18:00 in Los Angeles on September 22, already September 23 UTC.
    stamp = 1790125200.0
    rise, setting = sun_times(34.05, -118.24, stamp)
    assert rise < stamp < setting
    assert sun_factor(34.05, -118.24, .2, stamp) > .9


def test_sun_location_and_level_changes_take_effect_on_next_tick(clocks):
    ctrl = ControlState(); ctrl.apply({"sun": "on", "lat": 34, "lon": -118, "sun_night": .2})
    state = ctrl.tick_routines()
    assert state["sun_phase"] in ("day", "night", "dawn", "dusk")
    ctrl.apply({"lat": -34, "lon": 62, "sun_night": .7})
    changed = ctrl.tick_routines()
    assert state["sunrise_at"] != changed["sunrise_at"]
    assert changed["sun_factor"] == solar_status(ctrl.get(), clocks["wall"])["sun_factor"]
    ctrl.apply({"sun": "off"}); assert ctrl.tick_routines()["sun_factor"] == 1


def test_daily_schedules_observe_dst_and_wall_time(atlanta):
    winter = daily_at(date(2026, 1, 5), "07:00")
    summer = daily_at(date(2026, 7, 5), "07:00")
    assert time.gmtime(winter).tm_hour == 12
    assert time.gmtime(summer).tm_hour == 11
    spring = daily_at(date(2026, 3, 8), "02:30")
    assert time.localtime(spring)[3:5] == (3, 30)
    fold = daily_at(date(2026, 11, 1), "01:30")
    assert time.localtime(fold).tm_isdst == 1
    # Next means tomorrow, not the repeated 01:30 later that same morning.
    assert time.localtime(next_daily("01:30", fold + 1)).tm_mday == 2


def test_wake_only_lifts_off_once_and_cancel_stays_off(atlanta, clocks):
    clocks["wall"] = daily_at(date(2026, 9, 23), "07:00")
    ctrl = ControlState(); ctrl.apply({"mode": "off", "wake_enabled": True, "wake_time": "07:00", "wake_fade_min": 20})
    state = ctrl.tick_routines()
    assert ctrl.get()["mode"] == "art" and state["wake_active"]
    state = step(ctrl, clocks, 600)
    assert state["wake_progress"] == .5
    assert state["wake_next_end_at"] - state["wake_next_at"] == 1200
    ctrl.apply({"mode": "off"}); state = step(ctrl, clocks, 1)
    assert not state["wake_active"] and ctrl.get()["mode"] == "off"


def test_wake_does_not_dim_a_wall_already_on(atlanta, clocks):
    clocks["wall"] = daily_at(date(2026, 9, 23), "07:00")
    ctrl = ControlState(); ctrl.apply({"mode": "clock", "wake_enabled": True})
    state = ctrl.tick_routines()
    assert not state["wake_active"] and state["effective_brightness"] == 1
    ctrl.apply({"mode": "off"}); step(ctrl, clocks, 1)
    assert ctrl.get()["mode"] == "off"


def test_alarm_once_per_day_and_restores_previous_face(atlanta, clocks):
    clocks["wall"] = daily_at(date(2026, 9, 23), "07:00")
    ctrl = ControlState(); ctrl.apply({"mode": "clock", "alarm_enabled": True})
    state = ctrl.tick_routines()
    assert state["timer_kind"] == "alarm" and state["timer_ringing"]
    ctrl.apply({"timer_min": 0}); step(ctrl, clocks, 1)
    assert ctrl.timer is None and ctrl.get()["mode"] == "clock"
    step(ctrl, clocks, 86400)
    assert ctrl.timer is not None


@pytest.mark.parametrize("side", [64, 192, 512])
def test_clock_composition_is_exactly_scale_equivalent(side):
    stamp = 1790163000
    small = Clock(64, "#e8b04b", False).frame_at(0, when=stamp)
    actual = np.asarray(Clock(side, "#e8b04b", False).frame_at(0, when=stamp))
    # Integral panel multiples retain all calendar letters and both time rows.
    assert np.count_nonzero(actual[:side//5]) > 0
    assert np.count_nonzero(actual[side//5:side//2]) > 0
    assert np.count_nonzero(actual[side//2:]) > 0
    # The calendar and complete time stack remain pixel-identical at native
    # integral scales. Only the rail's moving dot uses the higher precision.
    from PIL import Image
    expected = np.asarray(small.resize((side, side), Image.Resampling.NEAREST))
    assert np.array_equal(actual[:side * 61 // 64], expected[:side * 61 // 64])


@pytest.mark.parametrize("remaining,total", [(150,300), (10800,10800), (0,300), (-1,300)])
def test_routine_preview_matches_live_renderer_without_mutation(api, remaining, total):
    before = api.ctrl.get()
    code, result = api.post("/routines/preview", {"face":"timer", "remaining_s":remaining, "total_s":total})
    assert code == 200
    expected = Countdown(64, before["color"], before["color2"]).frame_at(remaining,total)
    assert base64.b64decode(result["px"]) == expected.tobytes()
    assert api.ctrl.get() == before and api.ctrl.timer is None


def test_clock_preview_uses_selected_format_and_timestamp(api):
    stamp = 1790163000
    code, result = api.post("/routines/preview", {"face":"clock", "at":stamp, "twenty_four":False})
    assert code == 200
    assert base64.b64decode(result["px"]) == Clock(64,api.ctrl.get()["color"],False).frame_at(0,when=stamp).tobytes()


@pytest.mark.parametrize("patch", [{"at":float("nan")}, {"total_s":0}, {"remaining_s":20000}, {"face":"unknown"}, {"twenty_four":"false"}])
def test_bad_preview_refused(api, patch):
    assert api.post("/routines/preview", patch)[0] == 400


def test_cancel_timer_honors_an_explicit_destination(clocks):
    ctrl = ControlState(); ctrl.apply({"mode":"ambient", "timer_min":1})
    ctrl.apply({"timer_min":0, "mode":"clock"})
    assert ctrl.get()["mode"] == "clock" and ctrl.timer is None


def test_effective_brightness_accounts_for_actual_idle_face():
    ctrl = ControlState(); ctrl.apply({"brightness":.8})
    ctrl.idle_now = "black"
    assert ctrl.public_state()["effective_brightness"] == 0
    ctrl.idle_now = "dim"
    assert ctrl.public_state()["effective_brightness"] == pytest.approx(.24)
    ctrl.apply({"mode":"clock"})
    assert ctrl.public_state()["effective_brightness"] == .8


@pytest.mark.parametrize("key", ["alarm_time", "wake_time"])
@pytest.mark.parametrize("value", ["¹²:00", "٠٧:٣٠", "24:00", "07:60", "7:00", "00:00:00"])
def test_daily_time_requires_an_ascii_hhmm_value(key, value):
    ctrl = ControlState()
    assert key in ctrl.apply({key: value})
    assert ctrl.get()[key] == "07:00"
