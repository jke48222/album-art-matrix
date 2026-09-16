"""The control API, driven the way the phone drives it: over HTTP.

control.py was the largest thing in the brain with no test at all, so this
runs the real serve() against a real ControlState and asks it real questions.
Nothing here is mocked except the wall itself; the routing, the JSON, the
feature switches and the body limits are the ones that ship.

conftest.py points the state files at tmp_path, so a run never touches the
wall's own control.json or journal.

    .venv/bin/python -m pytest brain/tests/test_control.py -q
"""
import base64
import json
import os
import socket
import sys
import urllib.error
import urllib.request

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain import control                                        # noqa: E402
from brain.control import BODY_MAX, ControlState, serve          # noqa: E402
from brain.features import KNOWN, Features                       # noqa: E402


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
def api(request):
    """A brain on a port of its own, with the features the test asks for.

    Mark a test with @pytest.mark.features(note=False) to turn switches off.
    """
    marker = request.node.get_closest_marker("features")
    cfg = {"features": dict(marker.kwargs)} if marker else {}

    # No wall passed: ControlState builds the real 64x64 single panel,
    # which is what the Pi is today.
    ctrl = ControlState(frame_len=64 * 64 * 3)
    ctrl.features = Features(cfg)
    port = _free_port()
    httpd = serve(ctrl, port)
    try:
        yield _Client(ctrl, port)
    finally:
        httpd.shutdown()
        httpd.server_close()


class _Client:
    def __init__(self, ctrl, port):
        self.ctrl, self.port = ctrl, port
        self.base = f"http://127.0.0.1:{port}"

    def get(self, path):
        return self._do(urllib.request.Request(self.base + path))

    def post(self, path, obj=None, raw=None, headers=None):
        body = raw if raw is not None else json.dumps(obj or {}).encode()
        req = urllib.request.Request(self.base + path, data=body, method="POST")
        for k, v in (headers or {}).items():
            req.add_header(k, v)
        return self._do(req)

    @staticmethod
    def _do(req):
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                raw = r.read()
                try:
                    return r.status, json.loads(raw)
                except json.JSONDecodeError:
                    return r.status, raw
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except json.JSONDecodeError:
                return e.code, raw


# ---- it answers at all ------------------------------------------------------

def test_health_and_state(api):
    code, body = api.get("/health")
    assert code == 200 and isinstance(body, dict)

    code, body = api.get("/state")
    assert code == 200
    assert body["mode"] == "art"                 # DEFAULTS, no saved state
    assert 0.05 <= body["brightness"] <= 1.0


def test_unknown_path_is_404(api):
    code, _ = api.get("/nothing-here")
    assert code == 404


def test_state_round_trips(api):
    code, _ = api.post("/state", {"mode": "clock", "brightness": 0.4})
    assert code == 200
    code, body = api.get("/state")
    assert body["mode"] == "clock"
    assert body["brightness"] == pytest.approx(0.4)


def test_state_names_what_it_refused_and_keeps_the_rest(api):
    """A patch is partial: the good keys land, the bad ones come back under
    "rejected" rather than failing the whole request."""
    code, body = api.post("/state", {"mode": "hovercraft", "brightness": 0.3})
    assert code == 200
    assert body["rejected"] == {"mode": "hovercraft"}
    after = api.get("/state")[1]
    assert after["mode"] == "art"                       # refused
    assert after["brightness"] == pytest.approx(0.3)    # landed


# ---- bodies -----------------------------------------------------------------

def test_body_must_be_a_json_object(api):
    assert api.post("/state", raw=b"not json")[0] == 400
    assert api.post("/state", raw=b"[1, 2, 3]")[0] == 400


def test_body_over_the_cap_is_refused_without_reading_it(api):
    """A Content-Length past BODY_MAX is answered 413 before the read.

    The Pi has under a gigabyte and a one-minute watchdog, so the header is
    believed only up to the cap. The body here is small: what is under test is
    that the claim alone is enough to be turned away."""
    code, body = api.post("/state", raw=b"{}",
                          headers={"Content-Length": str(BODY_MAX + 1)})
    assert code == 413
    assert "MB" in body["error"]


def test_a_body_at_the_cap_is_still_read(api):
    padding = "x" * 2000
    code, _ = api.post("/state", {"mode": "clock", "_pad": padding})
    assert code == 200


# ---- frames -----------------------------------------------------------------

def test_frame_takes_a_square_of_raw_rgb(api):
    px = bytes(64 * 64 * 3)
    code, _ = api.post("/frame", {"px": base64.b64encode(px).decode()})
    assert code == 200
    assert api.get("/state")[1]["mode"] == "frame"


def test_frame_refuses_the_wrong_number_of_bytes(api):
    code, _ = api.post("/frame", {"px": base64.b64encode(b"\x00" * 99).decode()})
    assert code == 400


def test_frame_refuses_bytes_that_are_not_base64(api):
    code, _ = api.post("/frame", {"px": "not base64 at all!!"})
    assert code == 400


# ---- the feature switches ---------------------------------------------------

def test_features_lists_every_known_switch(api):
    code, body = api.get("/features")
    assert code == 200
    assert {f["name"] for f in body["features"]} == {n for n, _ in KNOWN}
    assert body["off"] == []


@pytest.mark.features(note=False)
def test_note_off_means_off(api):
    """The switch used to be listed and ignored: notes went up anyway."""
    assert api.get("/features")[1]["off"] == ["note"]
    assert api.post("/note", {"text": "back at six"})[0] == 404
    assert api.get("/note")[0] == 404
    assert api.get("/state")[1]["mode"] == "art"        # nothing went up


def test_note_on_puts_words_on_the_panel(api):
    code, body = api.post("/note", {"text": "back at six", "minutes": 1})
    assert code == 200 and body["shown"] is True
    state = api.get("/state")[1]
    assert state["mode"] == "ticker"
    assert state["ticker_text"] == "back at six"


def test_note_wants_words(api):
    assert api.post("/note", {"text": "   "})[0] == 400


@pytest.mark.features(earworm=False)
def test_earworm_off_does_not_take_show_with_it(api):
    """They share one Shower. earworm=false used to do nothing at all, and
    show=false used to switch earworm off as a side effect."""
    assert api.post("/earworm", {"words": "i cannot stop"})[0] == 404
    # show is still on, so it gets past the switch and fails on its own
    # ground (this wall has no Shower built), not on earworm's.
    assert api.post("/show", {"query": "blond"})[0] == 404
    assert api.get("/features")[1]["off"] == ["earworm"]


@pytest.mark.features(show=False)
def test_show_off_leaves_earworm_alone(api):
    off = {f["name"] for f in api.get("/features")[1]["features"] if not f["on"]}
    assert off == {"show"}


# ---- the pages the phone reads ---------------------------------------------

@pytest.mark.parametrize("path", ["/services", "/features", "/homekit", "/voice",
                                  "/airplay", "/shelf", "/ask", "/teach", "/journal",
                                  "/weather", "/imagine"])
def test_every_get_the_phone_polls_answers_json(api, path):
    """None of these need their feature built: each says so in JSON rather
    than throwing, because the phone polls them all on a wall it has just
    met."""
    code, body = api.get(path)
    assert code in (200, 404), path
    assert isinstance(body, dict), path


def test_nowplaying_is_204_when_nothing_is(api):
    """No chain built, so nothing is playing: no content, not an error and
    not an empty object the phone would have to tell apart from a real one."""
    code, _ = api.get("/nowplaying")
    assert code == 204


def test_tuning_says_so_when_there_are_no_knobs(api):
    """Built by main.py, not by ControlState, so a bare brain has none."""
    code, body = api.get("/tuning")
    assert code == 503
    assert isinstance(body, dict) and body.get("error")


def test_services_never_returns_a_key(api):
    """Keys come back as yes/no. Anyone on the network can read this."""
    _, body = api.get("/services")
    flat = json.dumps(body)
    for leak in ("api_key", "\"token\"", "client_secret", "access_token"):
        assert leak not in flat, f"{leak} in GET /services"
    assert body["lastfm"]["key_set"] in (True, False)


def test_state_is_not_written_to_the_real_config(api):
    """The guard in conftest: prove it, rather than trust it."""
    api.post("/state", {"mode": "clock"})
    assert "tmp" in control.STATE_PATH or "pytest" in control.STATE_PATH
    assert not control.STATE_PATH.startswith(os.path.expanduser("~/.config"))


def test_a_path_that_only_looks_like_show_is_a_404_not_a_crash(api):
    """The routes are matched with startswith, so "/showtime" lands in the
    shower's branch. It must not be a 500."""
    for path in ("/showtime", "/playlist", "/imaginarium"):
        code, body = api.post(path, {"query": "x"})
        assert code == 404, path
        assert isinstance(body, dict), path
