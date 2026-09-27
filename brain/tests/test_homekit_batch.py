"""HomeKit pairing status, exact QR parity and reversible presentation."""
from types import SimpleNamespace
import math

import numpy as np
import pytest

from brain.homekit import HomeKit, code_frame, code_modules

URI = "X-HM://0023ISYWY7OSY"  # Authored test data, never a real wall credential.


class Controller:
    def __init__(self, mode="art", frame=None):
        self.state = {"mode": mode}
        self.frame_override = frame
        self.shown_seq = 0
        self.phone_side = 192
        self.wall = SimpleNamespace(width=64, fit=lambda px: px)
        self.changes = []

    def get(self):
        return dict(self.state)

    def apply(self, patch):
        self.state.update(patch)
        self.changes.append(patch)


def bridge(mode="art", frame=None, paired=False, television=True, sensors=True):
    ctrl = Controller(mode, frame)
    hk = HomeKit(ctrl, television=television, sensors=sensors)
    hk.driver = SimpleNamespace(state=SimpleNamespace(paired=paired, pincode=b"031-45-154"),
                                config_changed=lambda: None)
    hk.bridge = SimpleNamespace(xhm_uri=lambda: URI)
    hk.ready.set()
    return hk


def test_code_modules_and_matched_output_are_identical():
    modules = code_modules(URI)
    assert len(modules) == 21
    assert all(len(row) == 21 and set(row) <= {"0", "1"} for row in modules)
    small = np.frombuffer(code_frame(URI, 64), np.uint8).reshape(64, 64, 3)
    large = np.frombuffer(code_frame(URI, 192), np.uint8).reshape(192, 192, 3)
    assert np.array_equal(large, np.repeat(np.repeat(small, 3, axis=0), 3, axis=1))
    assert set(np.unique(small)) == {0, 150}
    scale, offset = 2, 11
    assert np.all(small[:offset] == 150)
    assert np.all(small[:, :offset] == 150)
    for y, row in enumerate(modules):
        for x, cell in enumerate(row):
            assert np.all(small[offset+y*scale:offset+(y+1)*scale,
                                offset+x*scale:offset+(x+1)*scale] == (0 if cell == "1" else 150))


@pytest.mark.parametrize("uri", ["", "https://example.com", "X-HM://", "X-HM://" + "A" * 40, None])
def test_invalid_setup_uri_rejected(uri):
    with pytest.raises(ValueError):
        code_modules(uri)


def test_code_rejects_panel_without_quiet_zone():
    with pytest.raises(ValueError):
        code_frame(URI, 28)


def test_startup_event_does_not_mean_bridge_ready():
    hk = HomeKit(Controller())
    hk.ready.set()
    status = hk.status()
    assert status["ready"] is False
    assert status["uri"] is None
    assert status["qr_modules"] is None
    assert not hk.show_code()
    assert not hk.refresh()


def test_error_does_not_mean_ready_or_expose_stale_code():
    hk = bridge()
    hk.error = "Bridge couldn't start"
    status = hk.status()
    assert status["ready"] is False
    assert status["code"] is None
    assert status["qr_modules"] is None
    assert not hk.show_code()


def test_status_reports_actual_accessories():
    hk = bridge(television=False, sensors=False)
    status = hk.status()
    assert status["television"] is False
    assert status["sensors"] is False
    assert status["faces"] == []
    assert status["qr_modules"] == code_modules(URI)


def test_show_and_hide_restore_original_frame_identity():
    original = b"original physical frame"
    hk = bridge("frame", original)
    assert hk.show_code()
    assert hk.ctrl.frame_override != original
    assert hk.status()["showing_code"]
    assert hk.ctrl.get()["mode"] == "frame"
    hk.hide_code()
    assert hk.ctrl.frame_override is original
    assert hk.ctrl.get()["mode"] == "frame"
    assert not hk.status()["showing_code"]


@pytest.mark.parametrize("mode", ["art", "off", "weather", "clip", "video"])
def test_hide_restores_previous_display_mode(mode):
    hk = bridge(mode)
    assert hk.show_code()
    hk.hide_code()
    assert hk.ctrl.get()["mode"] == mode


def test_repeat_show_extends_without_losing_return_point():
    hk = bridge("off")
    assert hk.show_code(30)
    assert hk.show_code(180)
    assert hk.status()["code_seconds_remaining"] in (179, 180)
    hk.hide_code()
    assert hk.ctrl.get()["mode"] == "off"


def test_hide_never_overwrites_a_new_picture():
    hk = bridge()
    assert hk.show_code()
    new = b"new picture from the phone"
    hk.ctrl.frame_override = new
    assert not hk.status()["showing_code"]
    assert hk.status()["code_seconds_remaining"] == 0
    hk.hide_code()
    assert hk.ctrl.frame_override is new
    assert hk.ctrl.get()["mode"] == "frame"


def test_hide_never_changes_a_new_mode():
    hk = bridge()
    assert hk.show_code()
    hk.ctrl.apply({"mode": "weather"})
    assert not hk.is_showing_code()
    hk.hide_code()
    assert hk.ctrl.get()["mode"] == "weather"


def test_reshow_after_new_picture_uses_new_return_point():
    hk = bridge()
    hk.show_code()
    new = b"new picture from the phone"
    hk.ctrl.frame_override = new
    assert hk.show_code()
    hk.hide_code()
    assert hk.ctrl.frame_override is new
    assert hk.ctrl.get()["mode"] == "frame"


@pytest.mark.parametrize("duration", [math.nan, math.inf, -math.inf, "invalid"])
def test_bad_duration_does_not_touch_wall(duration):
    hk = bridge()
    assert not hk.show_code(duration)
    assert hk.ctrl.changes == []
    assert not hk.status()["showing_code"]


def test_cannot_display_pairing_code_for_paired_bridge():
    hk = bridge(paired=True)
    assert not hk.show_code()
    assert hk.ctrl.changes == []


def test_render_failure_is_recoverable_without_changing_mode():
    hk = bridge("off")
    hk.ctrl.wall.fit = lambda px: None
    assert not hk.show_code()
    assert hk.status()["code_error"]
    assert hk.ctrl.get()["mode"] == "off"
    hk.ctrl.wall.fit = lambda px: px
    assert hk.show_code()
    assert hk.status()["code_error"] is None


def test_expired_code_does_not_claim_showing(monkeypatch):
    hk = bridge()
    hk.show_code()
    monkeypatch.setattr("brain.homekit.time.monotonic", lambda: hk._code_until + 1)
    assert not hk.status()["showing_code"]
    assert hk.status()["code_seconds_remaining"] == 0


def test_refresh_uses_driver_configuration_notification():
    hk = bridge(paired=True)
    called = []
    hk.driver.config_changed = lambda: called.append(True)
    assert hk.refresh()
    assert called == [True]


def test_refresh_failure_is_reported_without_killing_ready_bridge():
    hk = bridge(paired=True)
    def unavailable():
        raise OSError("stopped loop")
    hk.driver.config_changed = unavailable
    assert not hk.refresh()
    assert hk.status()["ready"] is True


def test_leaving_code_removes_it_from_saved_frame_without_changing_mode():
    original = b"an earlier drawing"
    hk = bridge("art", original)
    hk.show_code()
    hk.ctrl.apply({"mode": "weather"})
    hk.hide_code()
    assert hk.ctrl.frame_override is original
    assert hk.ctrl.get()["mode"] == "weather"


def test_reshow_after_mode_change_does_not_save_qr_as_previous_frame():
    original = b"an earlier drawing"
    hk = bridge("art", original)
    hk.show_code()
    hk.ctrl.apply({"mode": "weather"})
    hk.show_code()
    hk.hide_code()
    assert hk.ctrl.frame_override is original
    assert hk.ctrl.get()["mode"] == "weather"
