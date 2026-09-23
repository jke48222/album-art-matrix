"""Real Ask/Notes state and HTTP regressions without paid inference or hardware."""
import concurrent.futures
import math
import sys
import threading
import time
from types import SimpleNamespace

import pytest

from brain.ask import Asker
from brain.control import ControlState
from brain.tests.test_control import api  # noqa: F401 — real HTTP fixture


@pytest.fixture
def no_note_timer(monkeypatch):
    class Timer:
        callbacks = []
        def __init__(self, interval, callback):
            self.callback = callback
            self.cancelled = False
            self.callbacks.append(self)
        def start(self):
            pass
        def cancel(self):
            self.cancelled = True
    monkeypatch.setattr("brain.control.threading.Timer", Timer)
    return Timer


def test_take_down_is_immediate_and_restores_previous_face(api, no_note_timer):
    api.post("/state", {"mode": "clock"})
    assert api.post("/note", {"text": "Back at seven", "minutes": 30})[0] == 200
    assert api.get("/note")[1]["active"] is True
    code, body = api.post("/note", {"clear": True, "id": api.get("/note")[1]["id"]})
    assert code == 200 and body["cleared"] is True and body["active"] is False
    assert api.ctrl.get()["mode"] == "clock"
    assert no_note_timer.callbacks[-1].cancelled


def test_take_down_cannot_replace_a_newer_face(api, no_note_timer):
    api.post("/note", {"text": "Old note", "minutes": 1})
    old_id = api.get("/note")[1]["id"]
    api.post("/state", {"mode": "ambient"})
    assert api.get("/note")[1]["active"] is False
    assert api.post("/note", {"clear": True, "id": old_id})[0] == 409
    assert api.ctrl.get()["mode"] == "ambient"


def test_revisiting_ticker_does_not_resurrect_note(api, no_note_timer):
    api.post("/note", {"text": "Old note", "minutes": 1})
    api.post("/state", {"mode": "clock"})
    api.post("/state", {"mode": "ticker"})
    assert api.get("/note")[1]["active"] is False
    no_note_timer.callbacks[0].callback()
    assert api.ctrl.get()["mode"] == "ticker"


def test_note_over_ticker_restores_the_exact_original_composition(api, no_note_timer):
    original = {"mode": "ticker", "ticker_text": "Keep dancing", "ticker_colors": ["#abcdef"],
                "ticker_style": "tilt", "ticker_loop": False}
    api.post("/state", original)
    api.post("/note", {"text": "Back soon", "minutes": 1})
    api.post("/note", {"text": "Actually, back at six", "minutes": 2})
    assert no_note_timer.callbacks[0].cancelled
    no_note_timer.callbacks[0].callback()
    assert api.ctrl.get()["ticker_text"] == "Actually, back at six"
    api.post("/note", {"clear": True, "id": api.get("/note")[1]["id"]})
    assert {key: api.ctrl.get()[key] for key in original} == original


def test_note_countdown_never_expires_early(api, no_note_timer, monkeypatch):
    now = [100.0]
    monkeypatch.setattr("brain.control.time.monotonic", lambda: now[0])
    api.post("/note", {"text": "One more moment", "minutes": 1})
    now[0] = 159.8
    no_note_timer.callbacks[0].callback()
    assert api.get("/note")[1]["seconds_left"] == 1
    assert api.ctrl.get()["mode"] == "ticker"
    now[0] = 160.0
    assert api.get("/note")[1]["active"] is False
    assert api.ctrl.get()["mode"] == "art"


@pytest.mark.parametrize("duration", [None, "oops", float("nan"), float("inf"), -1, 0, 721, True])
def test_note_rejects_invalid_duration_without_changing_wall(api, no_note_timer, duration):
    code, _ = api.post("/note", {"text": "Do not send", "minutes": duration})
    assert code == 400
    assert api.ctrl.get()["mode"] == "art"
    assert not no_note_timer.callbacks


def test_note_normalizes_before_truncation(api, no_note_timer):
    api.post("/note", {"text": "  Coffee ❤︎\r\nCafe\u0301  ", "minutes": 1})
    note = api.get("/note")[1]
    assert note["text"] == api.ctrl.get()["ticker_text"]
    assert note["text"] == "Coffee ♥\nCafé"


def test_rejected_timer_action_cannot_clear_note(api, no_note_timer):
    api.post("/note", {"text": "Stay here", "minutes": 1})
    code, body = api.post("/state", {"timer_action": "stop", "timer_id": "stale", "mode": "off"})
    assert code == 200 and body["rejected"]
    assert api.get("/note")[1]["active"] is True


def test_invalid_mode_does_not_clear_note(api, no_note_timer):
    api.post("/note", {"text": "Stay here", "minutes": 1})
    api.post("/state", {"mode": "invalid"})
    assert api.get("/note")[1]["active"] is True


@pytest.fixture
def asker(monkeypatch):
    class FakeError(Exception):
        pass
    module = SimpleNamespace(AuthenticationError=type("Auth", (FakeError,), {}),
                             RateLimitError=type("Rate", (FakeError,), {}),
                             APIConnectionError=type("Connection", (FakeError,), {}),
                             APIStatusError=type("Status", (FakeError,), {}))
    monkeypatch.setitem(sys.modules, "anthropic", module)
    result = SimpleNamespace(stop_reason="end_turn", content=[SimpleNamespace(type="text", text="Four records so far.")],
                             usage=SimpleNamespace(input_tokens=12, output_tokens=5))
    value = Asker(ControlState(), api_key="test-key")
    value._client = SimpleNamespace(messages=SimpleNamespace(create=lambda **kwargs: result))
    return value, module


def test_answer_is_kept_and_pending_is_released(asker):
    value, _ = asker
    reply = value.ask_reply("What played?")
    assert reply == {"answer": "Four records so far.", "error": None, "busy": False}
    assert value.status()["pending"] is False
    assert value.history[0]["q"] == "What played?"
    assert value.answers == 1


def test_client_construction_failure_is_an_error_and_releases_pending(asker, monkeypatch):
    value, _ = asker
    monkeypatch.setattr(value, "_client_", lambda: (_ for _ in ()).throw(RuntimeError("Client unavailable")))
    reply = value.ask_reply("A question")
    assert reply["answer"] is None and reply["error"]
    assert value.pending is False and not value.history
    assert value._ask_lock.acquire(blocking=False)
    value._ask_lock.release()


def test_network_failure_never_becomes_an_answer_or_history(asker):
    value, module = asker
    value._client.messages.create = lambda **kw: (_ for _ in ()).throw(module.APIConnectionError())
    reply = value.ask_reply("A question")
    assert reply["answer"] is None and "network" in reply["error"].lower()
    assert not value.history and value.answers == 0 and value.pending is False


def test_second_question_cannot_charge_while_first_is_pending(asker):
    value, _ = asker
    started, finish = threading.Event(), threading.Event()
    original = value._client.messages.create
    def blocked(**kw):
        started.set()
        assert finish.wait(timeout=3)
        return original(**kw)
    value._client.messages.create = blocked
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(value.ask_reply, "First")
        try:
            assert started.wait(timeout=3)
            assert value.status()["pending"] is True
            assert value.ask_reply("Second")["busy"] is True
        finally:
            finish.set()
        assert future.result(timeout=3)["answer"]
    assert value.answers == 1 and len(value.history) == 1


def test_http_returns_failure_without_showing_error_as_answer(api, asker):
    value, module = asker
    value._client.messages.create = lambda **kw: (_ for _ in ()).throw(module.APIConnectionError())
    api.ctrl.asker = value
    api.ctrl.voice = SimpleNamespace(show_answer=lambda answer: pytest.fail("Do not present failures as wall answers"))
    code, result = api.post("/ask", {"text": "What played?", "reply": "wall"})
    assert code == 502 and result.get("error") and "answer" not in result


def test_http_text_reply_does_not_take_the_wall(api, asker):
    api.ctrl.asker = asker[0]
    api.ctrl.voice = SimpleNamespace(show_answer=lambda answer: pytest.fail("Text-only request cannot take the wall"))
    code, result = api.post("/ask", {"text": "What played?", "reply": "text"})
    assert code == 200 and result["answer"] == "Four records so far." and result["shown"] is False


@pytest.mark.parametrize("payload", [{"text": " "}, {"text": 14}, {"text": "x" * 2001}, {"text": "Hello", "reply": "speak"}])
def test_invalid_question_never_reaches_model(api, asker, payload):
    api.ctrl.asker = asker[0]
    assert api.post("/ask", payload)[0] == 400
    assert api.ctrl.asker.answers == 0


def test_stale_take_down_cannot_remove_newer_note(api, no_note_timer):
    api.post("/note", {"text": "First", "minutes": 1})
    old_id = api.get("/note")[1]["id"]
    api.post("/note", {"text": "Second", "minutes": 1})
    new_id = api.get("/note")[1]["id"]
    assert old_id != new_id
    assert api.post("/note", {"clear": True, "id": old_id})[0] == 409
    assert api.get("/note")[1]["text"] == "Second"
    assert api.post("/note", {"clear": True})[0] == 400
    assert api.get("/note")[1]["active"] is True
    assert api.post("/note", {"clear": True, "id": new_id})[0] == 200


@pytest.mark.parametrize("protected", ["off", "timer", "away"])
def test_answer_cannot_cover_protected_wall_state(api, asker, protected):
    api.ctrl.asker = asker[0]
    api.ctrl.voice = SimpleNamespace(show_answer=lambda answer: pytest.fail("Protected wall state must stay visible"))
    if protected == "off":
        api.ctrl.apply({"mode": "off"})
    elif protected == "away":
        api.ctrl.display_mode = "off"
    else:
        api.ctrl.apply({"timer_min": 1})
    code, result = api.post("/ask", {"text": "What played?", "reply": "wall"})
    assert code == 200 and result["answer"] and result["shown"] is False


def test_question_requests_use_remaining_deadline(asker):
    value, _ = asker
    observed = []
    original = value._client.messages.create
    def observe(**kwargs):
        observed.append(kwargs["timeout"])
        return original(**kwargs)
    value._client.messages.create = observe
    assert value.ask_reply("Question")["answer"]
    assert len(observed) == 1 and 0 < observed[0] <= 75


def test_note_interrupting_timer_resumes_face_before_timer(api, no_note_timer):
    api.ctrl.apply({"mode": "clock"})
    api.ctrl.apply({"timer_min": 5})
    assert api.ctrl.timer["ret"] == "clock"
    api.post("/note", {"text": "A note", "minutes": 1})
    note_id = api.get("/note")[1]["id"]
    assert api.ctrl.timer is None
    api.post("/note", {"clear": True, "id": note_id})
    assert api.ctrl.get()["mode"] == "clock" and api.ctrl.timer is None


def test_note_interrupting_video_recovers_its_return_face(api, no_note_timer):
    api.ctrl.apply({"mode": "video"})
    api.ctrl.video_ret = "ambient"
    api.post("/note", {"text": "A note", "minutes": 1})
    api.post("/note", {"clear": True, "id": api.get("/note")[1]["id"]})
    assert api.ctrl.get()["mode"] == "ambient"


def test_real_note_timer_expires_while_http_and_routines_are_polling(api):
    """Exercise the real Timer thread, not the deterministic expiry stand-in.

    A hardware trace initially looked like an expiry deadlock; localhost
    remained healthy and the LAN was dropping connections. This protects the
    full control lock path so a future locking regression is distinguishable.
    """
    api.ctrl.apply({"mode": "clock", "alarm_enabled": False, "wake_enabled": False})
    finish = threading.Event()
    failures = []

    def routine_poll():
        try:
            while not finish.wait(0.002):
                api.ctrl.tick_routines()
        except Exception as exc:
            failures.append(exc)

    worker = threading.Thread(target=routine_poll, daemon=True)
    worker.start()
    timers = []
    try:
        for _ in range(5):
            api.ctrl.note("A brief note", 0.001)
            timer = api.ctrl._note_timer
            timers.append(timer)
            while timer.is_alive():
                code, state = api.get("/state")
                assert code == 200 and state["mode"] in ("ticker", "clock")
                timer.join(timeout=0.01)
            # GET /note is deliberately after join: the timer, not the status
            # endpoint's lazy-expiry branch, must have restored the display.
            assert api.ctrl.get()["mode"] == "clock"
            assert api.get("/note")[1]["active"] is False
    finally:
        finish.set()
        for timer in timers:
            timer.cancel()
        worker.join(timeout=2)
    assert not worker.is_alive() and not failures
