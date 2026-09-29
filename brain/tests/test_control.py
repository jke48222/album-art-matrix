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

HEALTH_KEYS = {"fps", "fps_age_s", "fps_target", "sent_fps", "temp_c", "temp_log",
               "throttled", "uptime_s", "boot_s", "loop_age_s", "renderer", "memory",
               "storage", "quiet_s", "idle", "mode", "ytdlp"}


def test_health_and_state(api):
    code, body = api.get("/health")
    assert code == 200 and isinstance(body, dict)
    # every key an older phone reads, and every one the health page adds
    assert HEALTH_KEYS <= set(body)
    assert isinstance(body["temp_log"], list)

    code, body = api.get("/state")
    assert code == 200
    assert body["mode"] == "art"                 # DEFAULTS, no saved state
    assert 0.05 <= body["brightness"] <= 1.0


def test_state_names_the_wall(api, monkeypatch):
    monkeypatch.setattr(control, "_HOSTNAME", "album-matrix")
    wall = api.get("/state")[1]["wall"]
    assert wall["name"] == "album-matrix"
    assert (wall["width"], wall["height"], wall["frame_side"]) == (64, 64, 64)


def test_host_label_survives_a_missing_hostname(monkeypatch):
    def gone():
        raise OSError("no name")

    monkeypatch.setattr(control.socket, "gethostname", gone)
    assert control._host_label() == ""
    monkeypatch.setattr(control.socket, "gethostname", lambda: "album-matrix.lan")
    assert control._host_label() == "album-matrix"
    monkeypatch.setattr(control.socket, "gethostname", lambda: "x" * 80)
    assert len(control._host_label()) == 63


@pytest.mark.parametrize("tile,cols,rows", [(64, 1, 1), (64, 3, 3)])
def test_state_reports_wall_grid(tile, cols, rows):
    """The About page names the size and the panel count from this block."""
    from brain.wall import Wall
    ctrl = ControlState(frame_len=(tile * cols) ** 2 * 3, wall=Wall(tile=tile, cols=cols, rows=rows))
    wall = ctrl.public_state()["wall"]
    for key in ("width", "height", "tile", "cols", "rows"):
        assert isinstance(wall[key], int) and wall[key] > 0, key
    assert wall["width"] == wall["tile"] * wall["cols"]
    assert wall["height"] == wall["tile"] * wall["rows"]
    assert (wall["cols"], wall["rows"]) == (cols, rows)


def test_peek_does_not_refresh_presence(api):
    """The widget's reload reads with ?peek=1. Counting it as someone home
    would keep lifting Away at night."""
    api.ctrl.last_client = None
    assert api.get("/state?peek=1")[0] == 200
    assert api.ctrl.last_client is None
    assert api.get("/state?peek")[0] == 200
    assert api.ctrl.last_client is None
    assert api.get("/state")[0] == 200
    assert api.ctrl.last_client is not None


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


# ---- the phone's pressing ----------------------------------------------------

def test_the_same_pressing_sent_again_does_not_count_as_a_new_picture(api):
    """The phone re-sends its pressing freely (once a second while it waits
    for the wall to say it has it, many times in the second a song changes).
    The spin face rebuilds its record on pressing_seq, so a re-send of the
    same picture must not bump it, or the wall flickers between records."""
    import base64
    px = bytes((10, 20, 30)) * (64 * 64)
    body = {"px": base64.b64encode(px).decode(), "track": "jo1|whatcha doin"}
    assert api.post("/pressing", body)[0] == 204
    assert api.ctrl.pressing_seq == 1
    for _ in range(5):
        assert api.post("/pressing", body)[0] == 204
    assert api.ctrl.pressing_seq == 1                    # same picture: no rebuild
    assert api.ctrl.pressing[0] == "jo1|whatcha doin"

    # a new name for the same picture is kept for the phone's sake, no rebuild
    api.post("/pressing", {**body, "track": "jo1|whatcha doin (feat. x)"})
    assert api.ctrl.pressing_seq == 1
    assert api.ctrl.pressing[0] == "jo1|whatcha doin (feat. x)"

    # a different picture is a new record
    px2 = bytes((90, 20, 30)) * (64 * 64)
    api.post("/pressing", {"px": base64.b64encode(px2).decode(), "track": "jo1|whatcha doin"})
    assert api.ctrl.pressing_seq == 2


def test_archive_replay_can_be_explicitly_released(api):
    api.ctrl.replay_active = True
    code, body = api.post('/state', {'resume_music': True, 'mode': 'art'})
    assert code == 200 and api.ctrl.resume_music
    assert 'resume_music' not in api.ctrl.get()


def test_same_second_archive_entries_match_identity(api):
    api.ctrl.journal_read = lambda limit: [
        {'ts':1,'title':'First','artist':'A','art_url':'one'},
        {'ts':1,'title':'Second','artist':'B','art_url':'two'}]
    code, body = api.post('/replay', {'ts':1,'title':'Second','artist':'B'})
    assert code == 200 and api.ctrl.replay['art_url'] == 'two'
    assert api.ctrl.replay_active and not api.ctrl.resume_music


def test_display_preview_endpoints(api):
    code, body = api.get('/lyrics')
    assert code == 200 and body['state'] == 'idle'
    api.ctrl.apply({'speed':2, 'match_art': True})
    api.ctrl.art_colors = ['#e5a343','#ffffff','#215059']
    code, shots = api.get('/ambient/previews')
    assert code == 200 and len(shots) == 9
    assert all(len(base64.b64decode(value)) == 64*64*3 for value in shots.values())
    from brain.art.effects import Ambient
    assert base64.b64decode(shots['gradient']) == Ambient(64, 'gradient','#e5a343','#215059',2).frame_at(8).tobytes()


def test_services_reports_actual_configured_source_order_without_inventing_defaults(api):
    _, empty = api.get('/services')
    assert empty['source_order'] == []
    api.ctrl.source_order = ['spotify', 'phone', 'ears']
    _, configured = api.get('/services')
    assert configured['source_order'] == ['spotify', 'phone', 'ears']
    configured['source_order'].append('lastfm')
    assert api.ctrl.source_order == ['spotify', 'phone', 'ears']


# ---- the ticker's own ink and pace (C12-2) ----------------------------------

def test_the_ticker_keeps_its_own_ink_and_pace_apart_from_the_lamp(api):
    api.post("/state", {"color": "#4060ff", "speed": 0.5, "match_art": True})
    code, body = api.post("/state", {"mode": "ticker", "ticker_text": "Hello",
                                     "ticker_color": "#112233", "ticker_speed": 2})
    assert code == 200 and "rejected" not in body
    assert body["ticker_color"] == "#112233" and body["ticker_speed"] == pytest.approx(2.0)
    # the lamp's settings, untouched by a message
    assert body["color"] == "#4060ff" and body["speed"] == pytest.approx(0.5)
    assert body["match_art"] is True
    assert api.ctrl.ticker_own_ink() == "#112233"


def test_ticker_speed_is_clamped_and_a_bad_ticker_color_refused(api):
    _, body = api.post("/state", {"ticker_speed": 9})
    assert body["ticker_speed"] == pytest.approx(3.0)
    _, body = api.post("/state", {"ticker_speed": 0})
    assert body["ticker_speed"] == pytest.approx(0.1)
    for bad in ("#12345", "112233", "#12345g", 7, None):
        _, body = api.post("/state", {"ticker_color": bad})
        assert "ticker_color" in body["rejected"]
    _, body = api.post("/state", {"ticker_speed": "fast"})
    assert "ticker_speed" in body["rejected"]
    assert api.ctrl.get()["ticker_color"] == "#f4f1ea"          # the default, unchanged


def test_a_message_without_its_own_ink_keeps_the_lamps(monkeypatch):
    """Notes, the remote's Info key and spoken messages bring no ink, so the
    render loop gives them the lamp's (the album's under Match Art), as
    before the ticker had an ink of its own. A note over a message with its
    own ink hands that message back in it."""
    class Timer:
        def __init__(self, *args, **kwargs):
            self.daemon = True
        def start(self):
            pass
        def cancel(self):
            pass
    monkeypatch.setattr("brain.control.threading.Timer", Timer)
    ctrl = ControlState()
    ctrl.apply({"mode": "ticker", "ticker_text": "Info title"})
    assert ctrl.ticker_own_ink() is None
    ctrl.apply({"mode": "ticker", "ticker_text": "Mine", "ticker_color": "#112233"})
    assert ctrl.ticker_own_ink() == "#112233"
    ctrl.note("Back at seven", 30)
    assert ctrl.ticker_own_ink() is None                       # the note: the lamp's ink
    ctrl.clear_note()
    assert ctrl.get()["ticker_text"] == "Mine" and ctrl.ticker_own_ink() == "#112233"


def test_a_state_saved_before_the_ticker_had_an_ink_keeps_what_it_showed():
    with open(control.STATE_PATH, "w") as fh:
        json.dump({"mode": "ticker", "ticker_text": "Old", "color": "#aa0000", "speed": 0.4}, fh)
    ctrl = ControlState()
    s = ctrl.get()
    assert s["ticker_color"] == "#aa0000" and s["ticker_speed"] == pytest.approx(0.4)
    assert ctrl.ticker_own_ink() is None                       # drawn in the lamp's ink, as before
    with open(control.STATE_PATH, "w") as fh:
        json.dump({**s, "ticker_color": "#00aa00"}, fh)
    assert ControlState().ticker_own_ink() == "#00aa00"        # a message saved with its own ink


def test_services_says_asking_claude_is_off_in_a_sentence(api):
    _, body = api.get("/services")
    assert body["claude"] == {"ready": False, "state": "off",
                              "problem": "Asking Claude is switched off on this wall."}


# ---- /tuning, with a store attached ------------------------------------------

@pytest.fixture
def tuned(api):
    from brain.tuning import Tuning
    api.ctrl.tuning = Tuning({})
    return api


class _Renderer:
    def __init__(self):
        self.attached, self.connects = True, 1

    def __call__(self):
        return {"attached": self.attached, "connects": self.connects,
                "detached_s": None if self.attached else 0.5, "pending_s": None}


def test_tuning_lists_the_brightness_ceiling_first_in_panel(tuned):
    code, body = tuned.get("/tuning")
    assert code == 200
    first = body["knobs"][0]
    assert first["name"] == "panel_brightness" and first["group"] == "Panel"
    assert (first["min"], first["max"], first["step"], first["restart"]) == (1, 254, 1, False)
    assert first["label"] == "Brightness ceiling" and first["unit"] == "/254"
    assert body["values"]["panel_brightness"] == 160
    assert body["defaults"]["panel_brightness"] == 160
    assert body["renderer"] == {"state": "absent", "down_s": None}
    assert body["groups"][0]["title"] == "Panel drive"


def test_tuning_post_routes_the_ceiling_to_state(tuned, tmp_path):
    code, body = tuned.post("/tuning", {"panel_brightness": 120, "black_point": 4})
    assert code == 200 and "rejected" not in body
    assert body["values"]["panel_brightness"] == 120 and body["values"]["black_point"] == 4
    assert tuned.ctrl.get()["panel_brightness"] == 120
    assert (tmp_path / "panel-brightness").read_text() == "120"
    code, body = tuned.post("/tuning", {"panel_brightness": "bright"})
    assert body["rejected"] == ["panel_brightness"]
    assert tuned.ctrl.get()["panel_brightness"] == 120


def test_tuning_reset_restores_the_ceiling_and_keeps_true_colour(tuned):
    tuned.post("/state", {"wb_r": 0.9})
    tuned.post("/tuning", {"panel_brightness": 90, "gain_g": 0.7})
    code, body = tuned.post("/tuning/reset")
    assert code == 200
    assert body["values"]["panel_brightness"] == 160
    assert body["values"]["gain_g"] == body["defaults"]["gain_g"]
    assert tuned.ctrl.get()["wb_r"] == pytest.approx(0.9)


def test_tuning_answers_409_with_values_while_restarting(tuned, renderer_process):
    r = _Renderer()
    tuned.ctrl.tuning.renderer = r
    renderer_process.pids = [4242]
    code, body = tuned.post("/tuning", {"bit_depth": 48})
    assert code == 200 and body["renderer"]["state"] == "restarting"
    assert body["restarting"] is True
    r.attached = False
    code, body = tuned.post("/tuning", {"bit_depth": 32, "panel_brightness": 100})
    assert code == 409
    assert body["error"] == "The panel is still restarting. Try again in a moment."
    assert body["values"]["bit_depth"] == 48
    # nothing in the refused write landed, the ceiling included
    assert tuned.ctrl.get()["panel_brightness"] == 160
    assert tuned.post("/tuning/reset")[0] == 409
    assert tuned.post("/tuning/restart")[0] == 409
    assert renderer_process.kills == [4242]
    # a live knob still goes through
    code, body = tuned.post("/tuning", {"gain_r": 0.9})
    assert code == 200 and body["values"]["gain_r"] == 0.9


def test_tuning_restart_returns_values_and_said(tuned, renderer_process):
    tuned.ctrl.tuning.renderer = _Renderer()
    renderer_process.pids = [11, 12]
    code, body = tuned.post("/tuning/restart")
    assert code == 200
    assert body["said"] == "renderer relaunching (2 stopped)"
    assert body["renderer"]["state"] == "restarting" and "values" in body
    assert renderer_process.kills == [11, 12]


def test_tuning_restart_with_nothing_running_says_so(tuned):
    tuned.ctrl.tuning.renderer = _Renderer()
    code, body = tuned.post("/tuning/restart")
    assert code == 200 and body["said"] == "the renderer was not running"


def test_state_brightness_no_longer_rewrites_panel_type(tuned, tmp_path):
    tuned.post("/tuning", {"panel_type": 3})
    assert (tmp_path / "panel-type").read_text() == "3"
    tuned.post("/state", {"panel_brightness": 100})
    assert (tmp_path / "panel-brightness").read_text() == "100"
    assert (tmp_path / "panel-type").read_text() == "3"


def test_state_panel_type_is_rejected_and_leaves_the_file(tuned, tmp_path):
    tuned.post("/tuning", {"panel_type": 3})
    code, body = tuned.post("/state", {"panel_type": 6})
    assert code == 200 and "panel_type" in body["rejected"]
    assert "panel_type" not in tuned.get("/state")[1]
    assert (tmp_path / "panel-type").read_text() == "3"
    assert tuned.ctrl.tuning.get("panel_type") == 3


def test_a_saved_panel_type_is_ignored():
    with open(control.STATE_PATH, "w") as fh:
        json.dump({"mode": "clock", "panel_type": 4}, fh)
    ctrl = ControlState()
    assert ctrl.get()["mode"] == "clock" and "panel_type" not in ctrl.get()


def test_tuning_restart_and_reset_leave_the_connection_usable(tuned):
    """Neither reads a body. do_POST drains it, so the next request on a
    kept-alive connection is not spoiled by it."""
    import http.client
    conn = http.client.HTTPConnection("127.0.0.1", tuned.port, timeout=10)
    try:
        for path in ("/tuning/reset", "/tuning/restart"):
            conn.request("POST", path, body=b'{"ignored": true}',
                         headers={"Content-Type": "application/json"})
            assert conn.getresponse().read() and True
            conn.request("GET", "/state")
            response = conn.getresponse()
            assert response.status == 200 and json.loads(response.read())["mode"] == "art"
    finally:
        conn.close()
