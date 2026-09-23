"""Drive draft previews and note replacement through the shipping HTTP API."""
import base64
import time

import pytest

from brain import control
from brain.art.pixelfont import normalize
from brain.art.text_modes import Crawl, Ticker
from brain.control import ControlState, serve
from brain.features import Features
from brain.tests.test_control import _Client, _free_port


@pytest.fixture
def ticker_api(request):
    side = getattr(request, "param", 64)
    ctrl = ControlState(frame_len=side * side * 3)
    ctrl.features = Features({})
    port = _free_port()
    server = serve(ctrl, port)
    try:
        yield _Client(ctrl, port)
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize("ticker_api", [64, 192], indirect=True)
@pytest.mark.parametrize("style", ["across", "up", "tilt"])
def test_preview_is_the_production_frame_at_the_requested_phase(ticker_api, style):
    api, side = ticker_api, ticker_api.ctrl.wall.width
    text, colors = "I ❤️ YOU\n가나다", ["#ff4433", "#44ddaa", "#6699ff"]
    before, revision = api.ctrl.get(), api.ctrl.ticker_revision
    api.ctrl.last_frame = bytes([21, 43, 65]) * side * side
    frame_before = api.ctrl.last_frame
    code, result = api.post("/ticker/preview", {
        "text": text, "style": style, "colors": colors, "color": "#fedcba", "speed": 1.5, "phase": .45,
    })
    assert code == 200
    assert result["side"] == side
    arguments = dict(color="#fedcba", colors=colors, speed=1.5, loop=False)
    renderer = Ticker(side, normalize(text), **arguments) if style == "across" else Crawl(side, normalize(text), tilt=style == "tilt", **arguments)
    assert result["duration"] == pytest.approx(renderer.travel / renderer.px_per_s)
    assert result["time"] == pytest.approx(result["duration"] * .45)
    actual = base64.b64decode(result["px"], validate=True)
    assert len(actual) == side * side * 3
    assert actual == renderer.frame_at(result["time"]).tobytes()
    assert any(actual)
    assert api.ctrl.get() == before
    assert api.ctrl.ticker_revision == revision
    assert api.ctrl.last_frame == frame_before
    assert api.ctrl.frame_override is None


@pytest.mark.parametrize("ticker_api", [64, 192], indirect=True)
def test_empty_preview_is_blank_and_never_replaces_the_wall(ticker_api):
    before = ticker_api.ctrl.get()
    code, result = ticker_api.post("/ticker/preview", {"text": "\n \t", "style": "up"})
    assert code == 200
    assert base64.b64decode(result["px"]) == bytes(ticker_api.ctrl.wall.width ** 2 * 3)
    assert ticker_api.ctrl.get() == before


@pytest.mark.parametrize("patch", [
    {"text": 123}, {"text": "a" * 601}, {"style": "rising"}, {"style": "crawl"},
    {"color": "#fffff"}, {"color": "#ggffff"}, {"color": None},
    {"colors": "#ffffff"}, {"colors": ["#ff0000"] * 201}, {"colors": [None]},
    {"speed": None}, {"speed": {}}, {"speed": float("nan")},
    {"phase": float("inf")}, {"phase": "later"},
])
def test_invalid_preview_input_returns_400_without_mutation(ticker_api, patch):
    before, revision = ticker_api.ctrl.get(), ticker_api.ctrl.ticker_revision
    code, result = ticker_api.post("/ticker/preview", {"text": "HELLO", **patch})
    assert code == 400 and result["error"]
    assert ticker_api.ctrl.get() == before
    assert ticker_api.ctrl.ticker_revision == revision


def test_preview_rejects_non_object_json_and_clamps_finite_boundaries(ticker_api):
    assert ticker_api.post("/ticker/preview", raw=b"[]")[0] == 400
    before = ticker_api.ctrl.get()
    for speed, phase in [(-100, -100), (100, 100)]:
        code, result = ticker_api.post("/ticker/preview", {"text": "HELLO", "speed": speed, "phase": phase})
        assert code == 200
        assert result["time"] == (0 if phase < 0 else result["duration"])
        assert not any(base64.b64decode(result["px"]))
    assert ticker_api.ctrl.get() == before


@pytest.fixture
def manual_note_expiry(monkeypatch):
    class Timer:
        def __init__(self, *args, **kwargs):
            pass

        def start(self):
            pass

    monkeypatch.setattr(control.threading, "Timer", Timer)

    def expire(ctrl):
        ctrl._note_until = time.monotonic() - 2
        ctrl._note_over()

    return expire


def test_notes_clear_old_letter_colors_and_restore_the_original_face(ticker_api, manual_note_expiry):
    api = ticker_api
    assert api.post("/state", {"mode": "clock", "ticker_colors": ["#ff0000", "#00ff00"]})[0] == 200
    assert api.post("/note", {"text": "Back at six", "minutes": 1})[0] == 200
    state = api.ctrl.get()
    assert state["ticker_colors"] == []
    assert state["mode"] == "ticker"
    manual_note_expiry(api.ctrl)
    assert api.ctrl.get()["mode"] == "clock"


@pytest.mark.parametrize("replacement", ["Back at six", "A new creation"])
def test_expired_note_cannot_dismiss_a_new_ticker_even_with_the_same_words(ticker_api, manual_note_expiry, replacement):
    api = ticker_api
    assert api.post("/note", {"text": "Back at six", "minutes": 1})[0] == 200
    revision = api.ctrl.ticker_revision
    assert api.post("/state", {"mode": "ticker", "ticker_text": replacement, "ticker_style": "tilt"})[0] == 200
    assert api.ctrl.ticker_revision > revision
    manual_note_expiry(api.ctrl)
    assert api.ctrl.get()["mode"] == "ticker"
    assert api.ctrl.get()["ticker_text"] == replacement
    assert api.ctrl.get()["ticker_style"] == "tilt"


def test_replacement_note_keeps_original_return_face_and_ignores_old_timer(ticker_api, manual_note_expiry):
    api = ticker_api
    assert api.post("/state", {"mode": "ambient"})[0] == 200
    assert api.post("/note", {"text": "First", "minutes": 1})[0] == 200
    assert api.post("/note", {"text": "Second", "minutes": 2})[0] == 200
    api.ctrl._note_over()
    assert api.ctrl.get()["mode"] == "ticker"
    assert api.ctrl.get()["ticker_text"] == "Second"
    manual_note_expiry(api.ctrl)
    assert api.ctrl.get()["mode"] == "ambient"


def test_note_expiry_respects_a_manually_selected_face(ticker_api, manual_note_expiry):
    assert ticker_api.post("/note", {"text": "Back at six", "minutes": 1})[0] == 200
    assert ticker_api.post("/state", {"mode": "off"})[0] == 200
    manual_note_expiry(ticker_api.ctrl)
    assert ticker_api.ctrl.get()["mode"] == "off"
