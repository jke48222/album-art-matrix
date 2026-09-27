"""Temporary wall presentation: ownership, exact source pixels and restoration."""
import base64
import http.client
import json
import threading
import urllib.error
import urllib.request
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from brain import control, display_session
from brain.control import ControlState
from brain.homekit import HomeKit
from brain.main import _FrameTee
from brain.picture_connection import PictureConnection
from brain.show import Shower
from brain.tests.test_control import api  # noqa: F401
from brain.wall import Wall

TOKEN = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
OTHER = "11111111-2222-3333-4444-555555555555"


class QuietTimer:
    """Deterministic deadlines; tests advance monotonic time explicitly."""
    def __init__(self, seconds, callback, args=()):
        self.seconds, self.callback, self.args = seconds, callback, args
        self.cancelled = False
        self.daemon = False

    def start(self):
        pass

    def cancel(self):
        self.cancelled = True


@pytest.fixture
def clock(monkeypatch):
    now = [100.0]
    monkeypatch.setattr(display_session.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(display_session.threading, "Timer", QuietTimer)
    return now


def frame(side=64, color=(191, 191, 191)):
    return bytes(color) * side * side


def request(*, token=TOKEN, purpose="onboarding", pixels=None, seconds=5, patch=None):
    return {"token": token, "purpose": purpose, "seconds": seconds,
            "px": base64.b64encode(pixels if pixels is not None else frame()).decode(),
            "patch": patch or {}}


def test_identification_never_replaces_underlying_mode_frame_or_settings(clock):
    ctrl = ControlState(seed={"mode": "off", "brightness": .35, "wb_r": .7})
    original = frame(color=(21, 42, 84))
    ctrl.frame_override = original
    before = ctrl.get()
    receipt = ctrl.display_session.begin(request(patch={"brightness": .8}))
    assert receipt == {"active": True, "token": TOKEN, "purpose": "onboarding", "seconds_remaining": 5}
    assert ctrl.get() == before and ctrl.frame_override is original
    ctrl.display_session.end({"token": TOKEN})
    assert ctrl.get() == before and ctrl.frame_override is original
    assert ctrl.display_session.render((1, 1, 1)) is None


def test_expiry_without_phone_restores_the_previous_display(clock):
    ctrl = ControlState(seed={"mode": "ambient"})
    before = ctrl.get()
    ctrl.display_session.begin(request())
    clock[0] += 5
    assert ctrl.display_session.status() == {"active": False}
    assert ctrl.get() == before and ctrl.dirty.is_set()
    assert ctrl.display_session.render((1, 1, 1)) is None


def test_deadline_alone_clears_session(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request())
    timer = ctrl.display_session.timer
    clock[0] += 5
    timer.callback(*timer.args)
    assert ctrl.display_session.item is None


def test_renewed_session_ignores_its_previous_deadline(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request())
    old_timer = ctrl.display_session.timer
    clock[0] += 3
    ctrl.display_session.begin(request(pixels=frame(color=(1, 2, 3))))
    assert old_timer.cancelled
    clock[0] += 2
    old_timer.callback(*old_timer.args)
    assert ctrl.display_session.status()["seconds_remaining"] == 3
    assert ctrl.display_session.render((1, 1, 1))[0].tobytes() == frame(color=(1, 2, 3))


def test_stale_timeout_cannot_end_a_different_session(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request())
    old = ctrl.display_session.timer
    ctrl.display_session.end({"token": TOKEN})
    clock[0] += 2
    ctrl.display_session.begin(request(token=OTHER, purpose="panel"))
    clock[0] += 3
    old.callback(*old.args)
    assert ctrl.display_session.status()["token"] == OTHER


def test_competing_owner_and_stale_end_are_rejected(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request())
    with pytest.raises(RuntimeError):
        ctrl.display_session.begin(request(token=OTHER))
    with pytest.raises(RuntimeError):
        ctrl.display_session.end({"token": OTHER})
    with pytest.raises(RuntimeError):
        ctrl.display_session.begin(request(purpose="panel"))
    assert ctrl.display_session.status()["token"] == TOKEN


def test_same_owner_can_update_patch_without_resending_pixels(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration"))
    ctrl.display_session.begin({"token": TOKEN, "purpose": "calibration", "patch": {"wb_g": .65}})
    assert ctrl.display_session.item["px"] == frame()
    assert ctrl.display_session.item["patch"] == {"wb_g": .65}
    assert ctrl.get()["wb_g"] == 1


def test_new_session_requires_valid_source_pixels(clock):
    ctrl = ControlState()
    with pytest.raises(ValueError):
        ctrl.display_session.begin({"token": TOKEN, "purpose": "panel"})
    assert not ctrl.display_session.status()["active"]


@pytest.mark.parametrize("patch", [{"mode": "off"}, {"brightness": 0}, {"wb_r": .2},
                                   {"wb_b": 1.1}, {"wb_g": True}, {"wb_r": "0.5"},
                                   {"brightness": float("nan")}, {"wb_r": float("inf")}, []])
def test_invalid_preview_patch_is_rejected_without_mutating_session(clock, patch):
    ctrl = ControlState()
    ctrl.display_session.begin(request())
    bad = request(); bad["patch"] = patch
    with pytest.raises(ValueError):
        ctrl.display_session.begin(bad)
    assert ctrl.display_session.item["patch"] == {}
    assert ctrl.display_session.status()["active"]


@pytest.mark.parametrize("seconds", [0, 601, True, "5", float("inf"), float("nan")])
def test_invalid_duration_is_rejected(clock, seconds):
    ctrl = ControlState()
    with pytest.raises(ValueError):
        ctrl.display_session.begin(request(seconds=seconds))
    assert not ctrl.display_session.status()["active"]


def test_calibration_can_atomically_keep_only_valid_colour_gains(clock):
    ctrl = ControlState(seed={"brightness": .35})
    before = ctrl.get()
    ctrl.display_session.begin(request(purpose="calibration", patch={"brightness": .9, "wb_r": .6}))
    result = ctrl.display_session.end({"token": TOKEN, "keep": {"wb_r": .6, "wb_b": .75}})
    assert result == {"active": False}
    assert ctrl.get() == {**before, "wb_r": .6, "wb_b": .75}
    persisted = json.loads(Path(control.STATE_PATH).read_text())
    assert persisted["wb_r"] == .6 and persisted["brightness"] == .35
    assert not set(persisted) & {"token", "purpose", "px", "seconds"}


def test_calibration_persistence_failure_retains_session_and_original_gains(clock, monkeypatch):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration"))
    before = ctrl.get()
    def refuse(*args):
        raise OSError("disk full")
    monkeypatch.setattr(control.os, "replace", refuse)
    with pytest.raises(OSError):
        ctrl.display_session.end({"token": TOKEN, "keep": {"wb_r": .6}})
    assert ctrl.get() == before
    assert ctrl.display_session.status()["active"]
    assert not list(Path(control.STATE_PATH).parent.glob(".calibration-*"))


@pytest.mark.parametrize("purpose", ["onboarding", "panel", "guests"])
def test_other_previews_cannot_commit_colour_calibration(clock, purpose):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose=purpose))
    with pytest.raises(ValueError):
        ctrl.display_session.end({"token": TOKEN, "keep": {"wb_r": .6}})
    assert ctrl.get()["wb_r"] == 1 and ctrl.display_session.status()["active"]


def test_expired_measurement_cannot_commit(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration"))
    clock[0] += 5
    with pytest.raises(RuntimeError):
        ctrl.display_session.end({"token": TOKEN, "keep": {"wb_r": .6}})
    assert ctrl.get()["wb_r"] == 1
    assert ctrl.display_session.end({"token": TOKEN}) == {"active": False}


def test_brightness_is_not_saved_as_a_calibration_gain(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration"))
    with pytest.raises(ValueError):
        ctrl.display_session.end({"token": TOKEN, "keep": {"brightness": .8}})
    assert ctrl.display_session.status()["active"]


def test_home_pairing_code_cannot_be_covered(clock):
    ctrl = ControlState()
    ctrl.homekit = SimpleNamespace(is_showing_code=lambda: True)
    with pytest.raises(RuntimeError):
        ctrl.display_session.begin(request())
    assert not ctrl.display_session.status()["active"]


def test_exact_pixel_source_and_nearest_neighbour_parity_ignore_finish(clock):
    rng = np.random.default_rng(16)
    small = rng.integers(0, 256, size=(64, 64, 3), dtype=np.uint8)
    ctrl = ControlState(wall=Wall(tile=64, cols=3, rows=3), frame_len=192 * 192 * 3)
    expected = np.repeat(np.repeat(small, 3, axis=0), 3, axis=1).tobytes()
    for finish in ["clean", "dither", "poster"]:
        ctrl.apply({"finish": finish})
        ctrl.display_session.begin(request(pixels=small.tobytes()))
        source, _ = ctrl.display_session.render((1, 1, 1))
        assert source.size == (192, 192) and source.tobytes() == expected
        ctrl.display_session.end({"token": TOKEN})


def test_explicit_new_visual_command_wins_over_preview(clock):
    ctrl = ControlState(seed={"mode": "off"})
    ctrl.display_session.begin(request())
    ctrl.apply({"mode": "clock"})
    assert ctrl.get()["mode"] == "clock"
    assert not ctrl.display_session.status()["active"]
    assert ctrl.display_session.end({"token": TOKEN}) == {"active": False}
    assert ctrl.get()["mode"] == "clock"


def test_arriving_source_is_not_replaced_by_old_snapshot_after_preview(clock):
    ctrl = ControlState()
    old, incoming = frame(color=(11, 12, 13)), frame(color=(77, 88, 99))
    ctrl.frame_override = old
    ctrl.display_session.begin(request())
    ctrl.frame_override = incoming
    ctrl.now_showing = {"title": "The next record", "artist": "Tessera"}
    ctrl.display_session.end({"token": TOKEN})
    assert ctrl.frame_override is incoming
    assert ctrl.now_showing["title"] == "The next record"


def test_frame_upload_interrupts_preview_and_stays_after_stale_dismissal(api, clock):
    assert api.post("/display-session", request())[0] == 200
    incoming = frame(color=(77, 88, 99))
    assert api.post("/frame", {"px": base64.b64encode(incoming).decode()})[0] == 200
    assert not api.ctrl.display_session.status()["active"]
    assert api.post("/display-session/end", {"token": TOKEN}) == (200, {"active": False})
    assert api.ctrl.frame_override == incoming and api.ctrl.get()["mode"] == "frame"


@pytest.mark.parametrize("key,value", [("purpose", []), ("purpose", {}), ("purpose", "unknown"),
                                       ("token", "short"), ("token", 42), ("px", "not base64"),
                                       ("px", None), ("px", base64.b64encode(b"bad frame").decode())])
def test_malformed_display_request_returns_400_not_dropped_connection(api, clock, key, value):
    body = request(); body[key] = value
    status, error = api.post("/display-session", body)
    assert status == 400 and "error" in error
    assert api.get("/display-session") == (200, {"active": False})


@pytest.mark.parametrize("path", ["/display-session/extra", "/display-session/end/extra"])
def test_display_routes_match_exactly(api, clock, path):
    assert api.post(path, request())[0] == 404
    assert not api.ctrl.display_session.status()["active"]


def test_conflict_is_409_and_valid_end_restores_without_touching_mode(api, clock):
    api.ctrl.apply({"mode": "off"})
    assert api.post("/display-session", request())[0] == 200
    assert api.get("/display-session")[1]["purpose"] == "onboarding"
    assert api.post("/display-session", request(token=OTHER))[0] == 409
    assert api.post("/display-session/end", {"token": OTHER})[0] == 409
    assert api.post("/display-session/end", {"token": TOKEN}) == (200, {"active": False})
    assert api.ctrl.get()["mode"] == "off"


def test_http_persistence_error_is_actionable_and_retryable(api, clock, monkeypatch):
    assert api.post("/display-session", request(purpose="calibration"))[0] == 200
    def refuse(*args):
        raise OSError("disk full")
    monkeypatch.setattr(api.ctrl, "save_colour_gains", refuse)
    status, result = api.post("/display-session/end", {"token": TOKEN, "keep": {"wb_r": .6}})
    assert status == 503 and "save" in result["error"]
    assert api.get("/display-session")[1]["active"]


def test_invalid_state_change_does_not_dismiss_an_active_measurement(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration"))
    rejected = ctrl.apply({"brightness": "not a brightness"})
    assert "brightness" in rejected
    assert ctrl.display_session.status()["active"]


def test_temporary_gain_changes_only_the_balanced_output(clock):
    ctrl = ControlState(seed={"brightness": 1.0})
    ctrl.display_session.begin(request(purpose="calibration", patch={"wb_r": .5}))
    source, output = ctrl.display_session.render((1, 1, 1))
    assert source.tobytes() == frame()
    assert output[0] < output[1] == output[2] == 191
    assert ctrl.get()["wb_r"] == 1.0


def test_rejected_timer_transaction_cannot_dismiss_preview_through_an_ignored_mode(clock):
    ctrl = ControlState(seed={"mode": "art"})
    ctrl.display_session.begin(request(purpose="calibration"))
    rejected = ctrl.apply({"timer_action": "stop", "timer_id": "stale", "mode": "off"})
    assert "timer_action" in rejected and ctrl.get()["mode"] == "art"
    assert ctrl.display_session.status()["active"]


def test_nonvisual_state_edit_keeps_display_session(clock):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration"))
    assert ctrl.apply({"place": "Philadelphia, Pennsylvania"}) == {}
    assert ctrl.display_session.status()["active"]
    assert ctrl.get()["place"] == "Philadelphia, Pennsylvania"


# ---- the guest code never leaves the wall -----------------------------------

class Panel:
    """The sink under the tee: what reached the LEDs."""
    brightness = dither = None

    def __init__(self):
        self.shown = []

    def show(self, rgb888, pre_wb_img=None):
        self.shown.append(pre_wb_img.tobytes() if pre_wb_img is not None else rgb888)


def raw_frame(api, query=""):
    try:
        with urllib.request.urlopen(f"{api.base}/frame.raw{query}", timeout=10) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, None


def show_check(tee, ctrl):
    """One pass of the render loop with a check up."""
    source, balanced = ctrl.display_session.render((1, 1, 1))
    tee.show(balanced, pre_wb_img=source)


@pytest.mark.parametrize("purpose", sorted(display_session.DisplaySession.PURPOSES))
def test_only_the_guest_code_is_kept_out_of_the_shown_frame(api, clock, purpose):
    panel = Panel()
    tee = _FrameTee(panel, api.ctrl, 64)
    face = Image.new("RGB", (64, 64), (40, 80, 120))
    tee.show(bytes(64 * 64 * 3), pre_wb_img=face)
    check = frame(color=(250, 250, 250))
    assert api.post("/display-session", request(purpose=purpose, pixels=check))[0] == 200
    show_check(tee, api.ctrl)
    assert panel.shown[-1] == check
    # The other checks are mirrored on the phone from this same frame.
    reported = face.tobytes() if purpose == "guests" else check
    assert api.ctrl.last_frame == reported
    assert raw_frame(api) == (200, reported)
    assert raw_frame(api, "?side=32") == (200, api.ctrl.wall.phone_view(reported, 32))
    assert api.post("/display-session/end", {"token": TOKEN}) == (200, {"active": False})
    after = Image.new("RGB", (64, 64), (60, 20, 90))
    tee.show(bytes(64 * 64 * 3), pre_wb_img=after)
    assert raw_frame(api) == (200, after.tobytes())


def test_a_guest_code_on_a_wall_that_showed_nothing_is_not_served_either(api, clock):
    tee = _FrameTee(Panel(), api.ctrl, 64)
    code = frame(color=(250, 250, 250))
    assert api.post("/display-session", request(purpose="guests", pixels=code))[0] == 200
    show_check(tee, api.ctrl)
    assert api.ctrl.last_frame is None
    assert raw_frame(api) == (404, None)


# ---- HomeKit is asked before the control lock -------------------------------

def test_home_is_asked_about_its_code_without_the_control_lock_held(clock):
    ctrl = ControlState()
    asked, code_up = [], [True]

    def is_showing_code():
        # An RLock lets its holder straight back in, so only another thread
        # can tell whether begin() is holding it.
        free = []

        def probe():
            if ctrl._lock.acquire(blocking=False):
                ctrl._lock.release()
                free.append(True)
        other = threading.Thread(target=probe)
        other.start()
        other.join(2)
        asked.append(bool(free))
        return code_up[0]

    ctrl.homekit = SimpleNamespace(is_showing_code=is_showing_code)
    with pytest.raises(RuntimeError):
        ctrl.display_session.begin(request())
    code_up[0] = False
    ctrl.display_session.begin(request())
    assert ctrl.display_session.status()["active"]
    assert len(asked) >= 2 and all(asked)


class CodeLock:
    """HomeKit's code lock, saying when someone has had to wait for it."""
    def __init__(self):
        self.lock = threading.RLock()
        self.waiting = threading.Event()

    def __enter__(self):
        if not self.lock.acquire(blocking=False):
            self.waiting.set()
            self.lock.acquire()
        return self

    def __exit__(self, *exc):
        self.lock.release()


def test_a_check_starting_while_home_hides_its_code_cannot_deadlock(clock):
    ctrl = ControlState()
    hk = HomeKit(ctrl)
    hk.driver = SimpleNamespace(state=SimpleNamespace(paired=False), config_changed=lambda: None)
    hk.bridge = SimpleNamespace(xhm_uri=lambda: "X-HM://0023ISYWY7OSY")
    hk.ready.set()
    ctrl.homekit = hk
    assert hk.show_code() and hk.is_showing_code()
    code_lock = hk._code_lock = CodeLock()
    held, go, results = threading.Event(), threading.Event(), []

    def hide():
        # hide_code holds the code lock and then takes the control lock to
        # put the face back. Held here first so the check meets it part way.
        with code_lock:
            held.set()
            go.wait(2)
            hk.hide_code()

    def start():
        try:
            results.append(ctrl.display_session.begin(request()))
        except Exception as error:
            results.append(error)

    home = threading.Thread(target=hide, daemon=True)
    home.start()
    assert held.wait(2)
    phone = threading.Thread(target=start, daemon=True)
    phone.start()
    assert code_lock.waiting.wait(2)
    go.set()
    home.join(3)
    phone.join(3)
    assert not home.is_alive() and not phone.is_alive()
    assert isinstance(results[0], dict) and results[0]["active"]
    assert ctrl.get()["mode"] == "art"


# ---- what ends a check, and what leaves it up -------------------------------

@pytest.mark.parametrize("patch", [{"mode": "clock"}, {"brightness": .5}, {"wb_g": .8},
                                   {"timer_min": 5}, {"sleep_fade_min": 10},
                                   {"resume_music": True}], ids=lambda patch: next(iter(patch)))
def test_a_command_ends_the_check_but_a_face_putting_itself_back_does_not(clock, patch):
    ctrl = ControlState()
    ctrl.display_session.begin(request(purpose="calibration", seconds=600))
    assert ctrl.apply(dict(patch), interrupt=False) == {}
    assert ctrl.display_session.status()["active"]
    assert ctrl.apply(dict(patch)) == {}
    assert not ctrl.display_session.status()["active"]


def test_stopping_a_timer_ends_the_check(clock):
    ctrl = ControlState(seed={"mode": "clock"})
    ctrl.apply({"timer_min": 5})
    ctrl.display_session.begin(request(seconds=600))
    assert ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]}) == {}
    assert ctrl.get()["mode"] == "clock"
    assert not ctrl.display_session.status()["active"]


@pytest.mark.parametrize("noticed_by", ["its timer", "a status read"])
def test_a_note_running_out_leaves_the_check_up(clock, noticed_by):
    ctrl = ControlState(seed={"mode": "clock"})
    ctrl.note("Back at seven", 1)
    timer = ctrl._note_timer
    ctrl.display_session.begin(request(purpose="guests", seconds=600))
    clock[0] += 60
    if noticed_by == "its timer":
        timer.callback(*timer.args)
    else:
        assert ctrl.note_status()["active"] is False
    assert ctrl.get()["mode"] == "clock"
    assert ctrl.display_session.status()["active"]


def test_taking_a_note_down_by_hand_ends_the_check(clock):
    ctrl = ControlState(seed={"mode": "clock"})
    ctrl.note("Back at seven", 1)
    ctrl.display_session.begin(request(seconds=600))
    assert ctrl.clear_note(ctrl.note_status()["id"])
    assert ctrl.get()["mode"] == "clock"
    assert not ctrl.display_session.status()["active"]


def test_a_show_me_picture_running_out_leaves_the_check_up(clock):
    ctrl = ControlState(seed={"mode": "ambient"})
    shower = Shower(ctrl)
    assert shower.show_frame(Image.new("RGB", (64, 64), (200, 30, 30)), 30)
    timer = shower._timer
    ctrl.display_session.begin(request(purpose="panel", seconds=600))
    clock[0] += 30
    timer.callback(*timer.args)
    assert ctrl.get()["mode"] == "ambient"
    assert ctrl.display_session.status()["active"]
    # A picture someone asks for is a command, and it ends the check.
    assert shower.show_frame(Image.new("RGB", (64, 64), (30, 30, 200)), 30)
    assert not ctrl.display_session.status()["active"]


# ---- the picture check on a kept-alive connection ---------------------------

@pytest.mark.parametrize("google,code,state", [
    (None, 503, "off"), (("", ""), 409, "default"),
    (("A" * 39, "0123456789abcdef0"), 200, "checking")], ids=["show me off", "no key", "key saved"])
def test_picture_check_leaves_the_kept_alive_connection_usable(api, monkeypatch, google, code, state):
    # The check's own request to Google is not what is under test here.
    monkeypatch.setattr(PictureConnection, "_run", lambda self, *args: None)
    if google is not None:
        api.ctrl.shower = Shower(api.ctrl, google_key=google[0], google_cx=google[1])
    connection = http.client.HTTPConnection("127.0.0.1", api.port, timeout=10)
    try:
        connection.request("POST", "/pictures/check", body=b"{}",
                           headers={"Content-Type": "application/json"})
        checked = connection.getresponse()
        checked.read()
        kept = connection.sock
        connection.request("GET", "/services")
        services = connection.getresponse()
        body = json.loads(services.read())
        reused = kept is not None and connection.sock is kept
    finally:
        connection.close()
    assert checked.status == code
    assert services.status == 200 and reused
    assert body["google"]["state"] == state


def test_show_me_off_reports_the_same_fields_as_show_me_on():
    ctrl = ControlState()
    off = ctrl.services()["google"]
    ctrl.shower = Shower(ctrl)
    assert set(off) == set(ctrl.services()["google"])
    assert off["state"] == "off" and off["problem"] == "Show me is off on this wall."


def test_a_sleep_fade_finishing_leaves_the_check_up(clock):
    ctrl = ControlState(seed={"mode": "clock"})
    ctrl.display_session.begin(request(purpose="calibration", seconds=600))
    import time as real_time
    mono = real_time.monotonic()
    ctrl.sleep = {"t0": mono - 120, "minutes": 1}
    ctrl.tick_routines(now=real_time.time(), mono=mono)
    assert ctrl.sleep is None and ctrl.get()["mode"] == "off"
    assert ctrl.display_session.status()["active"]


def test_a_rung_timer_going_back_leaves_the_check_up(clock):
    ctrl = ControlState(seed={"mode": "clock"})
    ctrl.display_session.begin(request(purpose="panel", seconds=600))
    import time as real_time
    mono = real_time.monotonic()
    ctrl.timer = {"end": mono - 200, "total": 60.0, "ret": "clock"}
    ctrl.tick_routines(now=real_time.time(), mono=mono)
    assert ctrl.timer is None
    assert ctrl.display_session.status()["active"]
