"""Voice lifecycle regression tests: real state machine, no microphone/cloud."""
import threading
import time
from unittest.mock import patch

from brain.tests.test_voice import FakeCtrl, FakeWake, FakeTranscriber, FakeAsker, chunk
from brain.voice.voice import Voice, MAX_LISTEN_S


def voice():
    return Voice(FakeCtrl(), FakeWake(), FakeTranscriber("show the clock"),
                 asker=FakeAsker("A clear evening."), log=lambda _: None)


def wait_until(predicate):
    deadline = time.monotonic() + 3
    while not predicate() and time.monotonic() < deadline:
        time.sleep(0.005)
    assert predicate()


def test_wake_acknowledges_only_a_new_enabled_session():
    v = voice()
    v.configure(on=False)
    assert v.wake_now() is False
    assert v.state == "idle" and v.wakes == 0
    v.configure(on=True)
    assert v.wake_now() is True
    assert v.wake_now() is False
    assert v.wakes == 1


def test_empty_oversized_or_disabled_typed_requests_do_not_run():
    v = voice()
    assert v.say("  ") is False
    assert v.say("x" * 1001) is False
    v.configure(on=False)
    assert v.say("show the clock") is False
    assert not v.ctrl.applied


def test_disconnected_microphone_does_not_leave_wall_listening():
    v = voice()
    assert v.wake_now(100)
    v.frame(100 + MAX_LISTEN_S + 0.1, 64)
    assert v.state == "missed"
    v.frame(v.since + 2, 64)
    assert v.state == "idle"


def test_microphone_freshness_clears_stale_levels():
    v = voice()
    with patch("brain.voice.voice.time.monotonic", return_value=10):
        assert v.meter()["mic_available"] is False
        v.feed(chunk(False), -30, -50, 10)
        assert v.meter()["mic_available"] is True
        assert v.meter()["level_over"] == 20
    with patch("brain.voice.voice.time.monotonic", return_value=14):
        assert v.meter()["mic_available"] is False
        assert v.meter()["level_over"] is None
        assert v.meter()["last_audio_ago"] == 4


def test_disabling_during_transcription_prevents_delayed_command():
    v = voice()
    entered, release = threading.Event(), threading.Event()
    def transcribe(_):
        entered.set()
        assert release.wait(2)
        return "show the clock"
    v.transcriber.transcribe = transcribe
    v.wake_now()
    generation = v._generation
    thread = threading.Thread(target=v._think, args=(b"audio", generation))
    thread.start()
    assert entered.wait(1)
    v.configure(on=False)
    v.configure(on=True)
    release.set()
    thread.join(2)
    assert not thread.is_alive()
    assert v.state == "idle" and not v.ctrl.applied
    assert not v.status()["history"]


def test_disabled_late_answer_cannot_reopen_wall():
    v = voice()
    entered, release = threading.Event(), threading.Event()
    def ask(*_, **__):
        entered.set()
        assert release.wait(2)
        return "Old answer."
    v.asker.ask = ask
    assert v.say("why is the sky blue")
    assert entered.wait(1)
    v.configure(on=False)
    v.configure(on=True)
    release.set()
    time.sleep(0.05)
    assert v.state == "idle" and v._face_answer is None
    assert v.last_answer is None


def test_recent_history_is_bounded_and_does_not_reuse_previous_answer():
    v = voice()
    assert v.say("what is this")
    wait_until(lambda: len(v.status()["history"]) == 1)
    assert "Nights" in v.status()["history"][0]["answer"]
    v._finish()
    for index in range(10):
        assert v.say("show the clock")
        wait_until(lambda: v.state == "idle" and len(v.status()["history"]) == min(index + 2, 8))
        # Await the specific worker's history append, even after the deque fills.
        time.sleep(0.005)
    history = v.status()["history"]
    assert len(history) == 8
    assert len({item["id"] for item in history}) == 8
    assert all(item["answer"] is None for item in history)
    assert all(item["text"] == "show the clock" for item in history)


def test_failed_wake_loading_unblocks_retry():
    v = voice()
    with patch("brain.voice.voice.wake_mod.choices", return_value=[{"name": "test"}]), \
         patch("brain.voice.voice.wake_mod.WakeWord", side_effect=RuntimeError("bad model")):
        response = v.set_wake("test", wait=True)
    assert response["ok"] is False
    assert "bad model" in response["error"]
    assert v._wake_loading is None
    assert isinstance(v.wake, FakeWake)


def test_competing_wake_load_is_refused():
    v = voice()
    v._wake_loading = "other"
    with patch("brain.voice.voice.wake_mod.choices", return_value=[{"name": "test"}]):
        response = v.set_wake("test")
    assert "already loading" in response["error"]
    assert v._wake_loading == "other"


def test_disabling_voice_cancels_an_active_enrollment():
    v = voice()
    assert v.enroll_start("Hey Tessera")["enroll"]["stage"] == "takes"
    v.configure(on=False)
    assert v.state == "idle"
    assert v.enroller.stage == "cancelled"
    assert v.enroller.finished_at is not None
    assert "switched off" in v.enroller.message


def test_microphone_dropout_cancels_enrollment_in_render_loop():
    v = voice()
    v.enroll_start("Hey Tessera")
    since = v.since
    v._last_audio = since + 1
    assert v.frame(since + 10, 64) is None
    assert v.state == "idle"
    assert v.enroller.stage == "cancelled"
    assert "microphone" in v.enroller.message
