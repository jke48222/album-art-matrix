"""Atomic ending actions and deterministic, legible completion choreography."""
import base64

import numpy as np
import pytest

from brain.art.text_modes import Countdown
from brain.control import ControlState
from brain.tests.test_control import api
from brain.tests.test_routines_batch import clocks, step


def finish(ctrl, clocks, seconds=42):
    ctrl.apply({"timer_min": seconds / 60})
    step(ctrl, clocks, seconds)
    return ctrl.public_state()["timer_id"]


@pytest.mark.parametrize("prior", ["art", "clock", "ambient", "frame", "clip", "off"])
def test_repeat_keeps_exact_duration_and_original_return_face(prior, clocks):
    ctrl = ControlState(); ctrl.apply({"mode": prior})
    event = finish(ctrl, clocks, 42)
    assert not ctrl.apply({"timer_action": "repeat", "timer_id": event})
    state = ctrl.public_state()
    assert state["timer_id"] != event and state["timer_remaining_s"] == 42
    assert state["timer_total_s"] == 42 and state["timer_kind"] == "countdown"
    assert not state["timer_ringing"] and not state["timer_snoozed"]
    assert ctrl.timer["ret"] == prior
    assert not ctrl.apply({"timer_action": "stop", "timer_id": state["timer_id"]})
    assert ctrl.get()["mode"] == prior


@pytest.mark.parametrize("prior", ["clock", "ambient", "off"])
def test_snooze_preserves_alarm_identity_and_schedule(prior, clocks):
    ctrl = ControlState(); ctrl.apply({"mode": prior, "alarm_enabled": True, "alarm_time": "09:41"})
    ctrl.ring(); event = ctrl.public_state()["timer_id"]
    assert not ctrl.apply({"timer_action": "snooze", "timer_id": event})
    state = ctrl.public_state()
    assert state["timer_remaining_s"] == 300 and state["timer_snoozed"]
    assert state["timer_kind"] == "alarm" and state["timer_id"] != event
    assert state["alarm_enabled"] and state["alarm_time"] == "09:41"
    clocks["wall"] += 3600  # Clock corrections do not shorten a snooze.
    assert ctrl.public_state()["timer_remaining_s"] == 300
    state = step(ctrl, clocks, 300)
    assert state["timer_kind"] == "alarm" and state["timer_ringing"]
    assert not ctrl.apply({"timer_action": "stop", "timer_id": state["timer_id"]})
    assert ctrl.get()["mode"] == prior


@pytest.mark.parametrize("action", ["stop", "repeat", "snooze"])
def test_stale_response_cannot_modify_replacement_timer(action, clocks):
    ctrl = ControlState(); old = finish(ctrl, clocks)
    ctrl.apply({"timer_min": 9}); active = dict(ctrl.timer)
    assert "timer_action" in ctrl.apply({"timer_action": action, "timer_id": old})
    assert ctrl.timer == active
    # Even a mixed patch is atomic when its command precondition is stale.
    assert "timer_action" in ctrl.apply({"timer_action": action, "timer_id": old, "mode": "off"})
    assert ctrl.timer == active and ctrl.get()["mode"] == "timer"


@pytest.mark.parametrize("action", ["repeat", "snooze", "unknown", None, True, {}])
def test_invalid_ending_action_leaves_running_countdown_intact(action, clocks):
    ctrl = ControlState(); ctrl.apply({"timer_min": 10})
    before = dict(ctrl.timer)
    assert "timer_action" in ctrl.apply({"timer_action": action, "timer_id": before["id"]})
    assert ctrl.timer == before


def test_snooze_and_repeat_cannot_be_crossed(clocks):
    ctrl = ControlState(); event = finish(ctrl, clocks)
    assert "timer_action" in ctrl.apply({"timer_action": "snooze", "timer_id": event})
    ctrl.ring(); event = ctrl.public_state()["timer_id"]
    assert "timer_action" in ctrl.apply({"timer_action": "repeat", "timer_id": event})


@pytest.mark.parametrize("extra", [{"idle": "unsupported"}, {"brightness": .3}, {"mode": "off"}, {"timer_min": 1}])
def test_ending_actions_reject_mixed_setting_updates_atomically(extra, clocks):
    ctrl = ControlState(); event = finish(ctrl, clocks)
    before, timer = ctrl.get(), dict(ctrl.timer)
    assert "timer_action" in ctrl.apply({"timer_action": "stop", "timer_id": event, **extra})
    assert ctrl.get() == before and ctrl.timer == timer


def test_snoozed_alarm_settles_and_restores_without_turning_off_schedule(clocks):
    ctrl = ControlState(); ctrl.apply({"mode": "ambient", "alarm_enabled": True})
    ctrl.ring()
    ctrl.apply({"timer_action": "snooze", "timer_id": ctrl.timer["id"]})
    state = step(ctrl, clocks, 479.9)
    assert state["timer_ring_elapsed_s"] == pytest.approx(179.9)
    state = step(ctrl, clocks, .1)
    assert ctrl.get()["mode"] == "ambient" and ctrl.timer is None
    assert state["timer_state"] == "idle" and state["timer_ring_elapsed_s"] == 0
    assert ctrl.get()["alarm_enabled"] and not state["timer_snoozed"]


def test_api_returns_ending_receipt_and_rejects_duplicate_tap(api, clocks):
    event = finish(api.ctrl, clocks)
    code, state = api.post("/state", {"timer_action": "repeat", "timer_id": event})
    assert code == 200 and "rejected" not in state and state["timer_remaining_s"] == 42
    _, rejected = api.post("/state", {"timer_action": "repeat", "timer_id": event})
    assert "timer_action" in rejected["rejected"]
    assert api.ctrl.timer["id"] == state["timer_id"]


@pytest.mark.parametrize("kind,snoozed,remaining", [("alarm", False, -2.5), ("alarm", True, 200), ("countdown", False, -2.5)])
def test_ending_previews_are_real_nonmutating_production_pixels(api, kind, snoozed, remaining):
    before = api.ctrl.get()
    code, result = api.post("/routines/preview", {"face": "timer", "kind": kind, "snoozed": snoozed,
                                               "remaining_s": remaining, "total_s": 300})
    assert code == 200
    assert base64.b64decode(result["px"]) == Countdown(64, before["color"], before["color2"]).frame_at(remaining, 300, kind, snoozed).tobytes()
    assert api.ctrl.get() == before and api.ctrl.timer is None


@pytest.mark.parametrize("side", [64, 192, 512])
def test_endings_are_distinct_and_labels_stay_still(side):
    timer = Countdown(side)
    done = np.asarray(timer.frame_at(-2, 600))
    alarm = np.asarray(timer.frame_at(-2, 600, "alarm"))
    later = np.asarray(timer.frame_at(-5, 600))
    assert not np.array_equal(done, alarm)
    assert not np.array_equal(done, later)
    assert np.array_equal(done[:side*12//64], later[:side*12//64])
    assert np.array_equal(done[side*54//64:], later[side*54//64:])
    assert done.shape == (side, side, 3) and done.dtype == np.uint8


@pytest.mark.parametrize("kind", ["countdown", "alarm"])
def test_ending_animation_has_no_full_field_flash(kind):
    renderer = Countdown(64)
    frames = [np.asarray(renderer.frame_at(-t / 30, 300, kind), dtype=float) for t in range(360)]
    differences = [np.abs(b-a).mean() for a, b in zip(frames, frames[1:])]
    assert max(differences) < .2
    levels = [frame.mean() for frame in frames]
    assert max(levels) - min(levels) < 2


@pytest.mark.parametrize("patch", [{"kind": "other"}, {"snoozed": "yes"}])
def test_preview_validates_ending_identity(api, patch):
    assert api.post("/routines/preview", {"face": "timer", **patch})[0] == 400
