"""Quiet-room policy and actual render-loop recovery regressions."""
from types import SimpleNamespace
import threading
import time

from PIL import Image
import pytest

from brain.rest import resolve_rest


def resolve(mode="art", **overrides):
    values = dict(idle="black", quiet_for=61, away="stay", presence_age=0,
                  playing=False, waking=False, sleeping=False,
                  weather_available=True)
    values.update(overrides)
    return resolve_rest(mode, **values)


@pytest.mark.parametrize("mode", ["art", "cd"])
@pytest.mark.parametrize("policy,visible,multiplier", [
    ("black", "off", 1), ("hold", None, 1), ("dim", None, .3),
    ("ambient", "ambient", 1), ("weather", "weather", 1),
])
def test_all_five_quiet_choices_preserve_selected_face(mode, policy, visible, multiplier):
    result = resolve(mode, idle=policy)
    assert result.mode == (visible or mode)
    assert result.brightness == multiplier
    assert result.idle == policy
    assert not result.away


@pytest.mark.parametrize("elapsed", [None, 0, 59.9, 60, float("nan"), float("inf")])
def test_no_early_or_unknown_idle_transition(elapsed):
    assert resolve(quiet_for=elapsed).mode == "art"


@pytest.mark.parametrize("mode", ["clock", "ambient", "weather", "frame", "ticker", "video", "lyrics"])
def test_quiet_does_not_replace_a_deliberately_selected_face(mode):
    assert resolve(mode).mode == mode
    assert resolve(mode).idle is None


@pytest.mark.parametrize("age", [None, 0, 899.9, 900, float("nan"), float("inf")])
def test_absence_requires_known_presence_older_than_fifteen_minutes(age):
    assert not resolve("clock", away="off", presence_age=age).away


def test_away_does_not_change_the_face_and_lifts_on_music_or_phone_contact():
    gone = resolve("clock", away="off", presence_age=901)
    assert gone.mode == "off" and gone.away
    assert resolve("clock", away="off", presence_age=0).mode == "clock"
    assert resolve("clock", away="off", presence_age=901, playing=True).mode == "clock"
    assert resolve("clock", away="stay", presence_age=901).mode == "clock"


@pytest.mark.parametrize("mode", ["art", "ambient", "clock"])
@pytest.mark.parametrize("active", ["waking", "sleeping"])
def test_scheduled_light_does_not_get_overridden_by_idle_or_away(mode, active):
    result = resolve(mode, away="off", presence_age=901, **{active: True})
    assert result.mode == mode and not result.away and result.idle is None


def test_off_and_timer_keep_their_own_meaning():
    for mode in ("off", "timer"):
        result = resolve(mode, away="off", presence_age=901)
        assert result.mode == mode and result.idle is None and not result.away
    assert resolve("off", playing=True, quiet_for=None).mode == "off"


def test_missing_weather_holds_cover_and_reports_actual_behavior():
    result = resolve("cd", idle="weather", weather_available=False)
    assert result.mode == "cd" and result.idle == "hold" and result.brightness == 1


def test_playing_without_art_protects_away_but_still_allows_quiet_policy():
    # A podcast/video without artwork is quiet for sleeve purposes, but
    # playback still proves the home is occupied.
    result = resolve(idle="dim", away="off", presence_age=901, playing=True)
    assert not result.away and result.idle == "dim"


@pytest.fixture
def running_wall(monkeypatch):
    """Only source, hardware and network IO are fixtures; run real main code."""
    from brain import main as runtime
    from brain.features import KNOWN

    controls, errors = [], []
    stop = threading.Event()
    source = SimpleNamespace(name="fixture", answer=None, phone_age=None)
    source.get_current = lambda: source.answer

    class EndLoop(BaseException):
        pass

    class Sink:
        def show(self, *args, **kwargs):
            if stop.is_set():
                raise EndLoop()

    def sources(config, control):
        controls.append(control)
        return [source]

    config = {"panel": {"width": 64, "height": 64}, "sink": {"type": "preview"},
              "nowplaying": {"poll_seconds": .02},
              "features": {name: False for name, _ in KNOWN}}
    monkeypatch.setattr(runtime, "load_config", lambda path: config)
    monkeypatch.setattr(runtime, "build_sources", sources)
    monkeypatch.setattr(runtime, "make_sink", lambda *args: Sink())
    monkeypatch.setattr(runtime, "serve_control", lambda *args: None)
    monkeypatch.setattr(runtime, "fetch_art", lambda url: Image.new("RGB", (64, 64), url))
    monkeypatch.setattr("sys.argv", ["brain", "--config", "fixture"])

    def run():
        try:
            runtime.main()
        except EndLoop:
            pass
        except BaseException as error:
            errors.append(error)

    thread = threading.Thread(target=run, daemon=True)
    thread.start()

    def wait(predicate):
        deadline = time.monotonic() + 4
        while not predicate() and not errors and time.monotonic() < deadline:
            time.sleep(.01)
        assert not errors, errors
        assert predicate()

    try:
        wait(lambda: bool(controls))
        yield SimpleNamespace(ctrl=controls[0], source=source, wait=wait)
    finally:
        stop.set()
        if controls:
            controls[0].last_client = time.monotonic()
            controls[0].apply({"mode": "clock", "away": "stay"})
            controls[0].dirty.set()
            controls[0].news.set()
        thread.join(5)
        assert not thread.is_alive()


def test_render_loop_away_preserves_face_timer_and_explicit_off(running_wall):
    from brain.nowplaying import NowPlaying
    ctrl, source, wait = running_wall.ctrl, running_wall.source, running_wall.wait
    ctrl.apply({"mode": "clock", "away": "off"})
    ctrl.last_client = time.monotonic() - 901
    ctrl.dirty.set()
    wait(lambda: ctrl.away_now and ctrl.display_mode == "off" and ctrl.last_frame is not None)
    assert ctrl.get()["mode"] == "clock"
    assert not any(ctrl.last_frame)
    assert ctrl.public_state()["effective_brightness"] == 0

    ctrl.last_client = time.monotonic()
    ctrl.dirty.set()
    wait(lambda: not ctrl.away_now and ctrl.display_mode == "clock" and any(ctrl.last_frame))
    assert ctrl.public_state()["effective_brightness"] > 0

    ctrl.last_client = time.monotonic() - 901
    ctrl.apply({"timer_min": 5})
    wait(lambda: ctrl.display_mode == "timer" and not ctrl.away_now)
    assert ctrl.timer is not None and ctrl.get()["mode"] == "timer"

    ctrl.apply({"timer_min": 0})
    wait(lambda: ctrl.away_now)
    ctrl.apply({"mode": "off"})
    ctrl.last_client = time.monotonic()
    ctrl.dirty.set()
    wait(lambda: ctrl.display_mode == "off" and not ctrl.away_now)
    source.answer = NowPlaying("a", "A", "Artist", "Album", "blue", 10000, 90000, True)
    ctrl.repoll.set()
    wait(lambda: ctrl.now_showing.get("title") == "A")
    assert ctrl.get()["mode"] == "off"
    assert not any(ctrl.last_frame)
    ctrl.apply({"mode": "art", "resume_music": True})
    wait(lambda: ctrl.display_mode == "art" and any(ctrl.last_frame))
    assert ctrl.finish_base.getpixel((32, 32)) == (0, 0, 255)


@pytest.mark.parametrize("face", ["frame", "nine"])
def test_cached_faces_repaint_after_away_and_timer_endings(running_wall, face):
    ctrl, wait = running_wall.ctrl, running_wall.wait
    if face == "frame":
        ctrl.frame_override = Image.new("RGB", (64, 64), (80, 150, 220)).tobytes()
    ctrl.apply({"mode": face, "away": "off"})
    ctrl.last_client = time.monotonic()
    wait(lambda: ctrl.display_mode == face and ctrl.last_frame is not None and any(ctrl.last_frame))
    original = ctrl.last_frame

    ctrl.last_client = time.monotonic() - 901
    ctrl.dirty.set()
    wait(lambda: ctrl.away_now and ctrl.display_mode == "off" and not any(ctrl.last_frame))
    assert ctrl.get()["mode"] == face
    # GET /state refreshes contact without sending a dirty repaint. Recovery
    # must therefore invalidate the cached drawing/grid by itself.
    ctrl.last_client = time.monotonic()
    wait(lambda: not ctrl.away_now and ctrl.display_mode == face and ctrl.last_frame == original)

    for ending in ("dismiss", "settle"):
        ctrl.apply({"timer_min": 1})
        wait(lambda: ctrl.display_mode == "timer" and ctrl.last_frame != original)
        event = ctrl.timer["id"]
        if ending == "dismiss":
            assert not ctrl.apply({"timer_action": "stop", "timer_id": event})
        else:
            # Move only the timer's monotonic deadline; the actual engine
            # performs its normal 3-minute completion and return behavior.
            with ctrl._lock:
                ctrl.timer["end"] = time.monotonic() - 181
            ctrl.dirty.set()
        wait(lambda: ctrl.timer is None and ctrl.display_mode == face and ctrl.last_frame == original)


def test_existing_voice_answer_cannot_cover_off_timer_or_away(running_wall, monkeypatch):
    from brain import main as runtime
    from brain.art.text_modes import Countdown
    from brain.voice import Voice
    ctrl, wait = running_wall.ctrl, running_wall.wait
    ctrl.apply({"mode": "clock", "away": "off"})
    ctrl.last_client = time.monotonic()
    wait(lambda: ctrl.display_mode == "clock" and ctrl.last_frame is not None)
    voice = Voice(ctrl, None, None, log=lambda _: None)
    ctrl.voice = voice
    assert voice.show_answer("A MOMENT TO REST")
    voice.since -= 2  # The production answer page has finished opening.
    answer = voice.frame(time.monotonic(), 64).tobytes()
    wait(lambda: ctrl.last_frame == answer)

    with ctrl._lock:
        ctrl.transition = ("open", time.monotonic(), (230, 220, 200))
        ctrl.apply({"mode": "off"})
    wait(lambda: ctrl.display_mode == "off" and not any(ctrl.last_frame))
    assert ctrl.transition is None
    assert voice.state == "answering"
    voice.since -= 300
    ctrl.dirty.set()
    wait(lambda: voice.state == "idle")
    assert not any(ctrl.last_frame)

    ctrl.apply({"mode": "clock"})
    assert voice.show_answer("A MOMENT TO REST")
    voice.since -= 2
    wait(lambda: ctrl.last_frame == voice.frame(time.monotonic(), 64).tobytes())
    rendered = {}

    class TrackedCountdown(Countdown):
        def frame_at(self, remaining, total, kind="countdown", snoozed=False):
            image = super().frame_at(remaining, total, kind, snoozed)
            rendered.update(pixels=image.tobytes(), ringing=remaining <= 0)
            return image

    monkeypatch.setattr(runtime, "Countdown", TrackedCountdown)
    ctrl.apply({"timer_min": 5})
    wait(lambda: ctrl.display_mode == "timer" and bool(rendered)
         and ctrl.last_frame == rendered["pixels"])
    assert voice.state == "answering"
    with ctrl._lock:
        ctrl.timer["end"] = time.monotonic() - .2
    ctrl.dirty.set()
    wait(lambda: rendered.get("ringing") and ctrl.last_frame == rendered["pixels"])

    assert not ctrl.apply({"timer_action": "stop", "timer_id": ctrl.timer["id"]})
    ctrl.last_client = time.monotonic() - 901
    ctrl.dirty.set()
    wait(lambda: ctrl.away_now and ctrl.display_mode == "off" and not any(ctrl.last_frame))
    assert voice.state == "answering"
    ctrl.voice = None
