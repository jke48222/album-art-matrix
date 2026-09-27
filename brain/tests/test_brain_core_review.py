"""Review fixes for the wall's core: control state, routines, the render loop,
the weather face and the lamp previews.

    .venv/bin/python -m pytest brain/tests/test_brain_core_review.py -q
"""
import base64
from datetime import date
import http.client
import json
import socket
import time
from types import SimpleNamespace
from unittest.mock import Mock

import numpy as np
from PIL import Image
import pytest

from brain.control import ControlState, serve
from brain.routines import daily_at, REST_HOLD_S
from brain.tests.test_control import api                        # noqa: F401  (fixture)
from brain.tests.test_rest_batch import running_wall            # noqa: F401  (fixture)


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


@pytest.fixture
def no_note_timer(monkeypatch):
    class Timer:
        def __init__(self, interval, callback):
            self.callback = callback
            self.daemon = True
        def start(self):
            pass
        def cancel(self):
            pass
    monkeypatch.setattr("brain.control.threading.Timer", Timer)


# ---- weather ---------------------------------------------------------------

def test_weather_off_says_off_rather_than_an_outage(api):
    code, body = api.get("/weather")
    assert code == 200 and body["off"] is True and body["problem"]


def test_a_location_saved_through_state_wakes_the_weather_once():
    ctrl = ControlState()
    ctrl.weather = SimpleNamespace(refresh=Mock())
    ctrl.apply({"lat": 39.95, "lon": -75.17, "place": ""})
    assert ctrl.weather.refresh.call_count == 1
    ctrl.apply({"lat": 39.95, "lon": -75.17})          # the same place again
    ctrl.apply({"brightness": .5})
    assert "lat" in ctrl.apply({"lat": 200})           # refused: nothing moved
    assert ctrl.weather.refresh.call_count == 1
    ctrl.apply({"lon": -75.2})
    assert ctrl.weather.refresh.call_count == 2


def test_weather_woken_by_coordinates_fetches_and_stops_saying_refreshing():
    from brain.weather import Weather
    from brain.tests.test_weather import fixture
    now = 1_760_000_000.0
    ctrl = ControlState()
    calls = []
    weather = Weather(ctrl, fetch=lambda *where: calls.append(where) or fixture(int(now)),
                      clock=lambda: now)
    ctrl.weather = weather
    weather.refresh()                                   # asked before any place
    weather.tick()
    assert calls == [] and weather.status()["refreshing"] is False
    weather._wake.clear()
    ctrl.apply({"lat": 39.95, "lon": -75.17})
    assert weather._wake.is_set()                       # the thread wakes now
    weather.tick()
    assert calls == [(39.95, -75.17)]
    assert weather.status()["refreshing"] is False and weather.current() is not None


def spoken(monkeypatch, size, *args, **kwargs):
    """Every text the weather face writes, in order."""
    from brain.art.weather import WeatherFace
    said = []
    original = WeatherFace._label
    def label(self, draw, text, *rest, **more):
        said.append(text)
        return original(self, draw, text, *rest, **more)
    monkeypatch.setattr(WeatherFace, "_label", label)
    try:
        WeatherFace(size).frame_at(0, *args, **kwargs)
    finally:
        monkeypatch.setattr(WeatherFace, "_label", original)
    return said


@pytest.mark.parametrize("size", [64, 192])
def test_a_named_forecast_without_a_place_name_is_your_weather(monkeypatch, size):
    data = dict(temp=22.8, code=3, is_day=False, high=24.4, low=17.2)
    said = spoken(monkeypatch, size, data, place="", lat=39.95, lon=-75.17)
    assert "Your weather" in said and "Choose a place" not in said
    waiting = spoken(monkeypatch, size, None, place="", lat=39.95, lon=-75.17)
    assert "Your weather" in waiting and "No weather yet" in waiting
    nowhere = spoken(monkeypatch, size, None, place="")
    assert "Choose a place" in nowhere and "Set in Tessera" in nowhere


@pytest.mark.parametrize("size", [64, 192])
def test_missing_temperature_is_two_hyphens_not_a_dash(monkeypatch, size):
    said = spoken(monkeypatch, size, dict(code=3), place="London")
    assert "--°" in said
    assert not any("—" in text or "–" in text for text in said)


def test_high_and_low_row_is_left_out_at_64_and_kept_at_192(monkeypatch):
    data = dict(temp=22.8, code=3, is_day=False, high=24.4, low=17.2)
    small = spoken(monkeypatch, 64, data, place="London")
    large = spoken(monkeypatch, 192, data, place="London")
    assert small == ["London", "73°", "Overcast"]
    assert "76°" in large and "63°" in large


def test_weather_idle_holds_the_cover_until_there_is_a_forecast(running_wall, monkeypatch):
    from brain import main as runtime
    from brain.rest import resolve_rest
    ctrl, wait = running_wall.ctrl, running_wall.wait
    seen = []
    def recorder(mode, **kwargs):
        seen.append(kwargs)
        return resolve_rest(mode, **kwargs)
    monkeypatch.setattr(runtime, "resolve_rest", recorder)
    forecast = {"value": None}
    ctrl.weather = SimpleNamespace(current=lambda: forecast["value"], where=lambda: None,
                                   stale=lambda: False, status=lambda: {})
    ctrl.apply({"idle": "weather"})
    wait(lambda: any(call["idle"] == "weather" for call in seen))
    assert all(call["weather_available"] is False for call in seen if call["idle"] == "weather")
    forecast["value"] = {"temp": 20, "code": 0, "is_day": True}
    seen.clear(); ctrl.dirty.set()
    wait(lambda: any(call["idle"] == "weather" and call["weather_available"] for call in seen))
    ctrl.weather = None


# ---- music faces and the journal -------------------------------------------

def test_face_switches_only_resume_music_during_a_replay():
    ctrl = ControlState()
    for face in ("art", "cd", "lyrics"):
        ctrl.apply({"mode": face})
        assert not ctrl.resume_music, face
    ctrl.replay_active = True
    ctrl.apply({"mode": "cd"})
    assert ctrl.resume_music
    ctrl.resume_music = False
    ctrl.apply({"mode": "art"}, replaying=True)
    assert not ctrl.resume_music
    ctrl.replay_active = False
    ctrl.apply({"mode": "clock", "resume_music": True})    # asked outright
    assert ctrl.resume_music and "resume_music" not in ctrl.get()


def test_replay_route_never_asks_for_the_music_first(api):
    api.ctrl.journal_read = lambda limit: [{"ts": 1, "title": "T", "artist": "A", "art_url": "u"}]
    seen = []
    original = api.ctrl.apply
    def apply(patch, **kwargs):
        rejected = original(patch, **kwargs)
        seen.append(api.ctrl.resume_music)
        return rejected
    api.ctrl.apply = apply
    assert api.post("/replay", {"ts": 1})[0] == 200
    assert seen == [False] and api.ctrl.replay_active


def test_switching_faces_and_restoring_after_archive_write_one_row(running_wall, monkeypatch):
    from brain.nowplaying import NowPlaying
    monkeypatch.setattr("brain.art.lyrics.fetch_sheet", lambda *args: None)   # no network
    ctrl, source, wait = running_wall.ctrl, running_wall.source, running_wall.wait
    source.answer = NowPlaying("one", "One", "Fixture", "Album", "blue", 40000, 180000, True)
    ctrl.repoll.set()
    wait(lambda: ctrl.now_showing.get("title") == "One")
    wait(lambda: len(ctrl.journal_read(10)) == 1)
    for face in ("cd", "art", "lyrics", "art"):
        ctrl.apply({"mode": face})
        wait(lambda: ctrl.display_mode == face)
    time.sleep(.3)                  # a resume would have been taken at once
    assert len(ctrl.journal_read(10)) == 1
    # An Archive replay, then the music back: the same song is re-shown,
    # not played again.
    ctrl.apply({"mode": "art"}, replaying=True)
    ctrl.replay = {"title": "Archive", "artist": "Fixture", "album": "Archive", "art_url": "red"}
    ctrl.news.set()
    wait(lambda: ctrl.now_showing.get("title") == "Archive")
    ctrl.apply({"mode": "art", "resume_music": True})
    wait(lambda: ctrl.now_showing.get("title") == "One" and not ctrl.replay_active)
    assert [row["title"] for row in ctrl.journal_read(10)] == ["One"]


def test_a_finished_once_only_message_cannot_take_down_a_newer_one(no_note_timer):
    ctrl = ControlState()
    ctrl.apply({"mode": "ticker", "ticker_text": "Once", "ticker_loop": False})
    finished = ctrl.ticker_revision
    ctrl.note("Back at six", 30)
    assert not ctrl.ticker_finished(finished)
    assert ctrl.get()["mode"] == "ticker" and ctrl.note_status()["active"]
    ctrl.clear_note()
    ctrl.apply({"mode": "ticker", "ticker_text": "Twice", "ticker_loop": False})
    assert ctrl.ticker_finished(ctrl.ticker_revision)
    assert ctrl.get()["mode"] == "art"


# ---- finishes, lamps, lyrics -----------------------------------------------

def test_naming_the_same_finish_base_again_is_not_a_change():
    ctrl = ControlState()
    picture = Image.new("RGB", (64, 64), "red")
    ctrl.finish_base = picture
    seq = ctrl.finish_seq
    for _ in range(5):
        ctrl.finish_base = picture
    assert ctrl.finish_seq == seq
    ctrl.finish_base = picture.copy()
    assert ctrl.finish_seq == seq + 1


def test_snake_plays_on_the_whole_of_a_large_wall():
    from brain.art.effects import Ambient
    for side in (64, 192):
        frame = np.asarray(Ambient(side, "snake", "#e5a343", "#215059", 1).frame_at(8))
        lit_y, lit_x = np.where(frame.max(axis=2) > 0)
        assert lit_x.max() >= side // 3 and lit_y.max() >= side // 3, side
    # The board starts in the middle of the wall, in cells six pixels wide:
    # the head's cell (16, 16) covers pixels 96 to 101.
    frame = np.asarray(Ambient(192, "snake", "#e5a343", "#215059", 1).frame_at(0.01))
    assert frame[96:102, 96:102].min() > 0


@pytest.fixture
def wall_192():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    ctrl = ControlState(frame_len=192 * 192 * 3)
    httpd = serve(ctrl, port)
    try:
        yield ctrl, port
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_lamp_previews_share_the_wall_composition_at_phone_size(wall_192):
    from brain.art.effects import Ambient
    ctrl, port = wall_192
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        conn.request("GET", "/ambient/previews")
        response = conn.getresponse()
        shots = json.loads(response.read())
    finally:
        conn.close()
    assert response.status == 200 and len(shots) == 9
    state = ctrl.get()
    assert all(len(base64.b64decode(shot)) == 64 * 64 * 3 for shot in shots.values())
    wall = Ambient(192, "plaid", state["color"], state["color2"], state["speed"]).frame_at(8)
    assert base64.b64decode(shots["plaid"]) == wall.resize((64, 64), Image.BOX).tobytes()
    assert ctrl._ambient_previews[0][-1] == 192


def test_a_failed_lyrics_lookup_is_tried_again_after_a_minute(monkeypatch):
    from brain.art import lyrics
    from brain.art.lyrics import LyricBook, LyricSheet
    answers = [OSError("offline"), LyricSheet([(0, "hello", [])])]
    def fetch(*args):
        answer = answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer
    monkeypatch.setattr(lyrics, "fetch_sheet", fetch)
    now = [100.0]
    book = LyricBook(clock=lambda: now[0])
    def settle():
        end = time.monotonic() + 2
        while book.state == "loading" and time.monotonic() < end:
            time.sleep(.01)
    book.ask("t", "a", "s", "al", 100); settle()
    assert book.state == "error"
    now[0] += 30
    book.ask("t", "a", "s", "al", 100)
    assert book.state == "error" and answers                 # too soon
    now[0] += 31
    book.ask("t", "a", "s", "al", 100); settle()
    assert book.state == "done" and not answers


# ---- routines --------------------------------------------------------------

def test_alarm_waits_for_a_countdown_over_its_minute_then_rings(atlanta, clocks):
    alarm = daily_at(date(2026, 9, 23), "07:00")
    clocks["wall"] = alarm - 300
    ctrl = ControlState()
    ctrl.apply({"mode": "clock", "alarm_enabled": True, "alarm_time": "07:00"})
    ctrl.apply({"timer_min": 10})
    step(ctrl, clocks, 330)                                   # 07:00:30, countdown still on
    assert ctrl.timer["kind"] == "countdown"
    state = step(ctrl, clocks, 60)
    assert state["alarm_next_at"] == alarm                    # still today's, waiting
    step(ctrl, clocks, 300)                                   # the countdown ends and rings
    ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})
    state = step(ctrl, clocks, 1)
    assert ctrl.timer is not None and ctrl.timer["kind"] == "alarm"
    assert ctrl.timer["ret"] == "clock"
    ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})
    state = step(ctrl, clocks, 1)
    assert ctrl.timer is None and state["alarm_next_at"] > alarm + 3600


def test_a_late_alarm_is_dropped_after_half_an_hour(atlanta, clocks):
    alarm = daily_at(date(2026, 9, 23), "07:00")
    clocks["wall"] = alarm - 60
    ctrl = ControlState()
    ctrl.apply({"mode": "clock", "alarm_enabled": True, "alarm_time": "07:00", "timer_min": 180})
    state = step(ctrl, clocks, 90)                            # due, but the countdown has it
    assert state["alarm_next_at"] == alarm
    state = step(ctrl, clocks, 1800)                          # 07:30:30, still counting
    # Dropped: the next alarm is tomorrow's, not today's, already past.
    assert state["alarm_next_at"] == daily_at(date(2026, 9, 24), "07:00")
    ctrl.apply({"timer_min": 0})
    state = step(ctrl, clocks, 1)
    assert ctrl.timer is None
    assert state["alarm_next_at"] == daily_at(date(2026, 9, 24), "07:00")


def test_alarm_sharing_the_wake_time_rings_at_full_light(atlanta, clocks):
    clocks["wall"] = daily_at(date(2026, 9, 23), "07:00")
    ctrl = ControlState()
    ctrl.apply({"mode": "off", "brightness": .8, "wake_enabled": True, "wake_time": "07:00",
                "alarm_enabled": True, "alarm_time": "07:00"})
    state = ctrl.tick_routines()
    assert ctrl.get()["mode"] == "timer"
    assert not state["wake_active"] and state["wake_factor"] == 1
    assert state["effective_brightness"] == pytest.approx(.8)
    ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})
    state = step(ctrl, clocks, 120)
    assert ctrl.get()["mode"] == "art" and state["wake_active"]     # the fade resumes
    assert state["wake_factor"] < 1


def test_sleep_completed_clears_once_the_wall_is_on_again(clocks):
    ctrl = ControlState()
    ctrl.apply({"sleep_fade_min": 1})
    step(ctrl, clocks, 61)
    assert ctrl.get()["mode"] == "off" and ctrl.public_state()["sleep_state"] == "completed"
    step(ctrl, clocks, 3600)
    assert ctrl.public_state()["sleep_state"] == "completed"       # still resting
    ctrl.apply({"mode": "art"})
    step(ctrl, clocks, 1)
    assert ctrl.public_state()["sleep_state"] == "idle"


def test_wake_lifts_a_wall_dark_from_idle_or_away_and_then_holds_it(atlanta, clocks):
    clocks["wall"] = daily_at(date(2026, 9, 23), "07:00")
    ctrl = ControlState()
    ctrl.apply({"mode": "art", "wake_enabled": True, "wake_time": "07:00", "wake_fade_min": 20})
    ctrl.display_mode = "off"                                 # idle black or Away
    state = ctrl.tick_routines()
    assert state["wake_active"] and ctrl.get()["mode"] == "art"
    assert ctrl.rest_hold_until is None
    step(ctrl, clocks, 1201)
    assert ctrl.rest_hold_until == pytest.approx(clocks["mono"] + REST_HOLD_S)


def test_wall_alarm_words_are_plain(monkeypatch):
    from brain.art.text_modes import Countdown
    said = []
    original = Countdown.text
    def text(self, canvas, words, *args, **kwargs):
        said.append(words)
        return original(self, canvas, words, *args, **kwargs)
    monkeypatch.setattr(Countdown, "text", text)
    face = Countdown(64, "#f4f1ea", "#e5a343")
    face.frame_at(-1, 60, "alarm")
    face.frame_at(-1, 60, "countdown")
    face.frame_at(30, 60, "countdown")
    assert "YOUR CUE" not in said and "REMAIN" not in said
    assert {"ALARM", "RINGING", "TIME UP", "ALL DONE", "LEFT"} <= set(said)


# ---- notes and the faces that come back after them --------------------------

@pytest.mark.parametrize("ending", ["timer", "alarm", "knock"])
def test_a_note_never_comes_back_after_whatever_interrupted_it(no_note_timer, clocks, ending):
    ctrl = ControlState()
    ctrl.apply({"mode": "clock"})
    ctrl.note("Back at seven", 30)
    if ending == "timer":
        ctrl.apply({"timer_min": 1})
        ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})
    elif ending == "alarm":
        ctrl.ring()
        step(ctrl, clocks, 181)                         # the alarm settles itself
    else:
        assert ctrl.knock_toggle("two knocks") == "off"
        ctrl.display_mode = "off"
        assert ctrl.knock_toggle("two knocks") == "on"
    assert ctrl.get()["mode"] == "clock"
    assert not ctrl.note_status()["active"]


def test_a_note_over_a_ticker_hands_back_the_owners_ticker(no_note_timer):
    ctrl = ControlState()
    ctrl.apply({"mode": "ticker", "ticker_text": "Keep dancing", "ticker_loop": True})
    ctrl.note("Back soon", 30)
    ctrl.apply({"timer_min": 1})
    assert ctrl.timer["ret"] == "ticker"
    ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})
    assert ctrl.get()["mode"] == "ticker" and ctrl.get()["ticker_text"] == "Keep dancing"


def test_returning_to_ticker_after_a_note_shows_the_owners_message(no_note_timer):
    """Any caller that remembered "ticker" as its face (older code, another
    module) still cannot bring the note back without an end."""
    ctrl = ControlState()
    ctrl.apply({"mode": "clock", "ticker_text": "Mine"})
    ctrl.note("Back at seven", 30)
    ctrl.apply({"mode": "frame"})
    ctrl.apply({"mode": "ticker"})
    assert ctrl.get()["ticker_text"] == "Mine"


def test_knock_at_a_wall_dark_from_away_or_idle_lights_it_and_saves_nothing(tmp_path):
    ctrl = ControlState()
    ctrl.apply({"mode": "art", "away": "off"})
    ctrl.display_mode = "off"                             # Away (or idle black) is blanking it
    assert ctrl.knock_toggle("two knocks") == "on"
    assert ctrl.get()["mode"] == "art" and ctrl.rest_hold_until > time.monotonic()
    ctrl.rest_hold_until = None
    assert ctrl.knock_toggle("a whistle down", want="off") == "off"
    assert ctrl.get()["mode"] == "art"                    # already dark: not saved as Off
    ctrl.display_mode = "art"
    assert ctrl.knock_toggle("two knocks") == "off"
    assert ctrl.get()["mode"] == "off"                    # a lit wall is turned off for real
    ctrl.display_mode = "off"
    assert ctrl.knock_toggle("two knocks") == "on"
    assert ctrl.get()["mode"] == "art" and ctrl.rest_hold_until is not None


def test_render_loop_honours_the_hold_a_knock_leaves(running_wall, monkeypatch):
    from brain import main as runtime
    from brain.rest import resolve_rest
    ctrl, wait = running_wall.ctrl, running_wall.wait
    seen = []
    def recorder(mode, **kwargs):
        seen.append(kwargs)
        return resolve_rest(mode, **kwargs)
    monkeypatch.setattr(runtime, "resolve_rest", recorder)
    ctrl.apply({"away": "off"})
    ctrl.last_client = time.monotonic() - 2000
    wait(lambda: ctrl.away_now)
    ctrl.display_mode = "off"
    assert ctrl.knock_toggle("two knocks") == "on"
    wait(lambda: not ctrl.away_now and ctrl.display_mode == "art")
    assert seen[-1]["presence_age"] == 0.0 and seen[-1]["quiet_for"] is None


# ---- routes ----------------------------------------------------------------

@pytest.fixture
def asker(api):
    api.ctrl.asker = SimpleNamespace(ready=True, status=lambda: {"ready": True},
                                     ask_reply=lambda text, size: {"answer": "Forty-two."})
    return api


def test_ask_says_why_an_answer_stayed_on_the_phone(asker):
    api = asker
    assert api.get("/ask")[1]["can_show"] is False
    code, body = api.post("/ask", {"text": "Why?"})
    assert code == 200 and body["shown"] is False and body["reason"] == "unavailable"
    api.ctrl.voice = SimpleNamespace(show_answer=Mock(return_value=True))
    assert api.get("/ask")[1]["can_show"] is True
    assert api.post("/ask", {"text": "Why?"})[1] == {"answer": "Forty-two.", "shown": True}
    api.ctrl.voice.show_answer.return_value = False
    assert api.post("/ask", {"text": "Why?"})[1]["reason"] == "busy"
    api.ctrl.apply({"timer_min": 5})
    assert api.post("/ask", {"text": "Why?"})[1]["reason"] == "timer"
    api.ctrl.apply({"mode": "off"})
    assert api.post("/ask", {"text": "Why?"})[1]["reason"] == "off"
    assert api.post("/ask", {"text": "Why?", "reply": "text"})[1] == {"answer": "Forty-two.", "shown": False}


@pytest.mark.features(show=False)
def test_imagine_draws_with_show_me_switched_off(api):
    api.ctrl.shower = None
    api.ctrl.imaginer = SimpleNamespace(begin=Mock(return_value={"accepted": True, "job_id": "j"}),
                                        imagine=Mock(return_value={"id": "art"}))
    assert api.post("/imagine", {"prompt": "An amber sun", "async": True})[0] == 202
    assert api.post("/imagine", {"prompt": "An amber sun"})[0] == 200
    api.ctrl.imaginer.begin.assert_called_once_with("An amber sun")
    api.ctrl.imaginer.imagine.assert_called_once_with("An amber sun")


@pytest.mark.features(show=False)
def test_a_shower_kept_for_earworm_still_reports_show_me_off(api):
    api.ctrl.shower = SimpleNamespace(status=lambda: {"key_set": True, "state": "ready"},
                                      discovery_status=lambda: {"last": {"id": "x"}},
                                      earworm_status=lambda: {"last": None, "ready": True},
                                      earworm=Mock(return_value={"shown": True}),
                                      last_picture_frame=lambda: b"png",
                                      picture_connection=SimpleNamespace(check=Mock(return_value=True)),
                                      show=Mock(return_value={"shown": True}))
    assert api.get("/show")[1] == {"last": None, "ready": False, "off": True}
    assert api.get("/earworm")[1]["ready"] is True
    assert api.get("/services")[1]["google"]["state"] == "off"
    assert api.get("/pictures/last.png")[0] == 404
    assert api.post("/pictures/check", {})[0] == 503
    assert api.post("/earworm", {"words": "never gonna give"})[0] == 200
    assert api.post("/show", {"query": "blond"})[0] == 404
    api.ctrl.shower.show.assert_not_called()


def test_show_me_on_reports_ready(api):
    api.ctrl.shower = SimpleNamespace(discovery_status=lambda: {"last": None, "pending": False})
    assert api.get("/show")[1] == {"ready": True, "last": None, "pending": False}


@pytest.mark.parametrize("on,built", [((), False), (("earworm",), True), (("imagine",), True),
                                      (("show",), True)])
def test_main_builds_one_shower_for_any_of_its_switches(monkeypatch, on, built):
    """Run main far enough to build its objects: earworm with Show me off
    used to have no shower at all."""
    import threading
    from brain import main as runtime
    from brain.features import KNOWN
    controls, errors = [], []
    class Built(BaseException):
        pass
    def sources(config, control):
        controls.append(control)
        control.services_store = SimpleNamespace(get=lambda *args: "")   # build_sources' job
        return [SimpleNamespace(name="fixture", get_current=lambda: None)]
    def sink(*args):
        raise Built()                     # everything before the sink is built by now
    config = {"panel": {"width": 64, "height": 64}, "sink": {"type": "preview"},
              "nowplaying": {"poll_seconds": .02},
              "features": {name: name in on for name, _ in KNOWN}}
    monkeypatch.setattr(runtime, "load_config", lambda path: config)
    monkeypatch.setattr(runtime, "build_sources", sources)
    monkeypatch.setattr(runtime, "make_sink", sink)
    monkeypatch.setattr(runtime, "serve_control", lambda *args: None)
    monkeypatch.setattr("sys.argv", ["brain", "--config", "fixture"])
    def run():
        try:
            runtime.main()
        except Built:
            pass
        except BaseException as error:
            errors.append(error)
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    thread.join(20)
    assert not errors and controls
    assert (controls[0].shower is not None) is built


def test_unsearchable_poster_title_is_a_clear_400(api):
    api.ctrl.posters = SimpleNamespace(check=Mock(return_value=False))
    code, body = api.post("/posters/check", {"title": "Netflix"})
    assert code == 400 and "episode" in body["error"]
    api.ctrl.posters.check.assert_not_called()
    assert api.post("/posters/check", {"title": "Severance"})[0] == 409


def test_games_off_status_decodes(api):
    body = api.get("/game")[1]
    assert body["seq"] == 0 and body["running"] is False


# ---- the shelf mark --------------------------------------------------------

def test_shelf_reads_rebuild_the_sleeve_only_when_its_mark_changes():
    from brain.main import _refresh_shelf_sleeve
    class Collection:
        owned = True
        def note_playing(self, album, artist):
            return {"release_id": 1} if self.owned else None
    shelf = Collection()
    sleeve = Image.new("RGB", (64, 64), (140, 140, 140))      # what the loop really holds
    shown = {"album": "Record", "artist": "Artist"}
    assert _refresh_shelf_sleeve(sleeve, shelf, shown, True, marked=True) is None
    marked = _refresh_shelf_sleeve(sleeve, shelf, shown, True, marked=False)
    assert isinstance(marked, Image.Image) and marked.tobytes() != sleeve.tobytes()
    shelf.owned = False
    assert _refresh_shelf_sleeve(sleeve, shelf, shown, True, marked=False) is None
    plain = _refresh_shelf_sleeve(sleeve, shelf, shown, True, marked=True)
    assert plain.tobytes() == sleeve.tobytes() and plain is not sleeve


# ---- kept-alive connections -------------------------------------------------

def test_homekit_actions_leave_the_connection_ready_for_the_next_poll():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    ctrl = ControlState()
    ctrl.homekit = SimpleNamespace(hide_code=Mock(), refresh=Mock(return_value=True),
                                   show_code=Mock(return_value=True),
                                   status=lambda: {"enabled": True, "showing_code": False})
    httpd = serve(ctrl, port)
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        for path in ("/homekit/hide", "/homekit/refresh", "/homekit/show?s=60", "/lyrics/retry"):
            conn.request("POST", path, body=b"{}", headers={"Content-Type": "application/json"})
            first = conn.getresponse()
            first.read()
            sock = conn.sock
            conn.request("GET", "/homekit")
            second = conn.getresponse()
            assert first.status == 200 and second.status == 200, path
            assert json.loads(second.read())["enabled"] is True
            assert conn.sock is sock, path
    finally:
        conn.close()
        httpd.shutdown()
        httpd.server_close()
