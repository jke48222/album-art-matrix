"""What the Home Screen widget reads from the wall, pinned.

The widget (tessera/Shared/WallSnapshot.swift and WallFacts.swift) reads
GET /state?peek=1 and GET /frame.raw with no ?side, and draws the frame at the
wall's own size. It maps /state the way the app does: the face is
display_mode, except during a guest code, when it is mode. None of this is a
brain change. These tests keep the brain from drifting out from under it.

Presence and ?peek are pinned in test_control.py
(test_peek_does_not_refresh_presence). The guest-code cover on a single panel,
for every display purpose, is test_display_session_batch.py
(test_only_the_guest_code_is_kept_out_of_the_shown_frame). This file adds the
nine-panel wall and the /state side of a guest code.
"""
import base64
import json
import urllib.error
import urllib.request

import pytest
from PIL import Image

from brain import display_session
from brain.control import ControlState, serve
from brain.main import _FrameTee
from brain.tests.test_control import _Client, _free_port, api  # noqa: F401
from brain.tests.test_display_session_batch import TOKEN, Panel, clock, show_check  # noqa: F401
from brain.wall import Wall


def guest_request(side=64):
    code = bytes((250, 250, 250)) * side * side
    return {"token": TOKEN, "purpose": "guests", "seconds": 5,
            "px": base64.b64encode(code).decode(), "patch": {}}


def raw(base):
    """GET /frame.raw with no ?side: status, bytes and the width header."""
    try:
        with urllib.request.urlopen(f"{base}/frame.raw", timeout=10) as r:
            return r.status, r.read(), r.headers.get("X-Frame-Width")
    except urllib.error.HTTPError as error:
        return error.code, None, None


@pytest.fixture
def nine():
    """A nine-panel wall (3 x 3 tiles of 64) on a port of its own."""
    ctrl = ControlState(frame_len=192 * 192 * 3, wall=Wall(tile=64, cols=3, rows=3))
    port = _free_port()
    httpd = serve(ctrl, port)
    try:
        yield _Client(ctrl, port)
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_state_carries_what_the_widget_reads(api):
    code, body = api.get("/state?peek=1")
    assert code == 200
    assert isinstance(body["mode"], str) and isinstance(body["display_mode"], str)
    assert isinstance(body["now_showing"], dict) and isinstance(body["now_playing"], dict)
    assert isinstance(body["wall"]["width"], int)
    assert body["display_session"]["active"] is False
    # The rest of what WallFacts reads: the rest policy, the weather's place
    # and the timer's receipt.
    assert "idle_active" in body and isinstance(body["away_active"], bool)
    assert isinstance(body["place"], str)
    assert body["timer_state"] == "idle" and body["timer_ringing"] is False


def test_guest_session_reports_underlying_mode_and_no_token(api, clock):
    api.post("/state", {"mode": "art"})
    assert api.post("/display-session", guest_request())[0] == 200
    code, body = api.get("/state?peek=1")
    assert code == 200
    # The widget takes the face from mode, never this.
    assert body["display_mode"] == "frame"
    assert body["mode"] == "art"
    assert body["display_session"]["active"] is True
    assert body["display_session"]["purpose"] == "guests"
    assert TOKEN not in json.dumps(body)

    def keys(value):
        if isinstance(value, dict):
            for k, v in value.items():
                yield k
                yield from keys(v)
        elif isinstance(value, list):
            for v in value:
                yield from keys(v)
    assert "token" not in set(keys(body))


def test_frame_raw_native_size_on_nine_panels(nine):
    tee = _FrameTee(Panel(), nine.ctrl, 192)
    face = Image.new("RGB", (192, 192), (40, 80, 120))
    tee.show(bytes(192 * 192 * 3), pre_wb_img=face)
    status, body, width = raw(nine.base)
    assert status == 200
    assert len(body) == 110_592 and body == face.tobytes()
    assert width == "192"


def test_guest_cover_at_native_size_on_nine_panels(nine, clock):
    tee = _FrameTee(Panel(), nine.ctrl, 192)
    before = Image.new("RGB", (192, 192), (60, 20, 90))
    tee.show(bytes(192 * 192 * 3), pre_wb_img=before)
    assert nine.post("/display-session", guest_request(192))[0] == 200
    show_check(tee, nine.ctrl)
    status, body, width = raw(nine.base)
    assert status == 200 and width == "192"
    # Byte for byte what was up before the code.
    assert body == before.tobytes()


def test_frame_raw_404_before_first_frame(api):
    status, body, _ = raw(api.base)
    assert status == 404 and body is None


def test_display_purposes_the_widget_names_are_the_brains():
    """WidgetReading titles each purpose it can see. Guests is the one it
    never names, and any purpose it does not know reads as a test pattern."""
    named = {"panel", "calibration", "onboarding", "identify", "tuning"}
    assert display_session.DisplaySession.PURPOSES == named | {"guests"}
