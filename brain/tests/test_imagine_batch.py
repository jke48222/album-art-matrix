"""Creation jobs, gallery ownership and streaming regressions; no inference calls."""
import base64
import concurrent.futures
import io
import threading
import time

import pytest
from PIL import Image

from brain.imagine import Imaginer, LiveDrawing, MAX_PROMPT
from brain.tests.test_imagine import Ctrl


def image_bytes(colour=(137, 183, 204)):
    output = io.BytesIO()
    Image.new("RGB", (32, 32), colour).save(output, "PNG")
    return output.getvalue()


@pytest.fixture
def studio(tmp_path):
    def post(*args):
        return {"data": [{"b64_json": base64.b64encode(image_bytes()).decode()}]}
    return Imaginer(Ctrl(), api_key="fixture-key", path=str(tmp_path / "images"), post=post)


@pytest.mark.parametrize("prompt", [None, 42, False, {}, [], "", " \n\t", "x" * (MAX_PROMPT + 1)])
def test_invalid_prompts_never_reserve_or_change_wall(studio, prompt):
    assert studio.begin(prompt).get("error")
    assert not studio.busy and studio.ctrl.s["mode"] == "art"
    assert studio.live.stage == "idle" and studio.listing() == []


def test_background_job_reserves_slot_before_paid_request(studio):
    started, finish = threading.Event(), threading.Event()
    calls = []
    def post(*args):
        calls.append(1)
        started.set()
        assert finish.wait(4)
        return {"data": [{"b64_json": base64.b64encode(image_bytes()).decode()}]}
    studio._post = post
    result = studio.begin("  a moon\n reflected in water  ")
    assert result["accepted"] and len(result["job_id"]) == 32
    try:
        assert started.wait(4)
        assert studio.status()["busy"] and studio.status()["job_id"] == result["job_id"]
        assert studio.status()["live"]["prompt"] == "a moon reflected in water"
        assert studio.begin("a second picture")["code"] == "busy"
        assert studio.show_again("does-not-matter")["code"] == "busy"
        assert studio.forget("does-not-matter")["code"] == "busy"
        # Settings changes are applied after the in-flight provider operation.
        studio.configure(provider="google", api_key="next-key", quality="high")
        assert studio.provider == "openai" and studio.api_key == "fixture-key"
    finally:
        finish.set()
    deadline = time.monotonic() + 4
    while studio.busy and time.monotonic() < deadline:
        time.sleep(0.005)
    assert not studio.busy and len(calls) == 1
    assert studio.provider == "google" and studio.api_key == "next-key"
    assert studio.listing()[0]["provider"] == "openai"
    assert studio.status()["showing_id"] == studio.listing()[0]["id"]


def test_finishing_after_user_changes_face_does_not_claim_to_show(studio):
    def post(*args):
        studio.ctrl.apply({"mode": "clock"})
        return {"data": [{"b64_json": base64.b64encode(image_bytes()).decode()}]}
    studio._post = post
    result = studio.imagine("The moon")
    assert result["imagined"] and result["shown"] is False
    assert studio.ctrl.s["mode"] == "clock" and studio.status()["on_wall"] is False
    studio.release()
    assert studio.ctrl.s["mode"] == "clock"


def test_forgetting_visible_picture_restores_original_face(studio):
    studio.ctrl.apply({"mode": "ambient"})
    result = studio.imagine("A new world")
    assert studio.ctrl.s["mode"] == "imagine"
    assert studio.forget(result["id"])["forgotten"] == result["id"]
    assert studio.ctrl.s["mode"] == "ambient" and studio.live.stage == "idle"
    assert studio.listing() == [] and studio.status()["last"] is None
    assert studio.status()["showing_id"] is None
    assert studio.forget(result["id"])["code"] == "not_found"


def test_forgetting_saved_picture_cannot_override_a_newer_face(studio):
    item = studio.imagine("A new world")
    studio.ctrl.apply({"mode": "off"})
    assert studio.forget(item["id"])["forgotten"]
    assert studio.ctrl.s["mode"] == "off"


def test_failed_restore_is_not_acknowledged_as_shown(studio):
    item = studio.imagine("A new world")
    studio.ctrl.apply({"mode": "clock"})
    studio.ctrl.apply = lambda patch: (_ for _ in ()).throw(RuntimeError("offline"))
    assert studio.show_again(item["id"])["code"] == "unavailable"
    assert studio.status()["on_wall"] is False


def test_disk_failure_finishes_job_and_reports_error(studio, monkeypatch):
    monkeypatch.setattr("brain.imagine.os.makedirs", lambda *a, **kw: (_ for _ in ()).throw(OSError("disk full")))
    result = studio.imagine("A new world")
    assert result["error"] and result["code"] == "unavailable"
    assert studio.live.stage == "failed" and not studio.busy
    assert studio.listing() == []


def test_stream_failure_never_launches_a_second_paid_request(studio):
    calls = []
    def stream(*args):
        calls.append("stream")
        yield {"type": "error", "error": {"message": "Service temporarily unavailable"}}
    def post(*args):
        calls.append("post")
        raise AssertionError("A generic streamed error must never retry a paid request")
    studio._stream, studio._post = stream, post
    assert studio.imagine("A new world")["error"]
    assert calls == ["stream"] and not studio.busy


def test_stream_duplicate_partial_events_do_not_count_as_progress(studio):
    raw = base64.b64encode(image_bytes()).decode()
    def stream(*args):
        for index in [0, 0, -1, 5, 1, 1, 2]:
            yield {"type": "image_generation.partial_image", "partial_image_index": index, "b64_json": raw}
        yield {"type": "image_generation.completed", "b64_json": raw}
    studio._stream = stream
    assert studio.imagine("A new world")["imagined"]
    assert studio.live.public()["partials"] == 3
    assert len(studio.live.images) == 4


def test_expiry_and_status_use_zero_timestamp_correctly():
    now = [0.0]
    live = LiveDrawing(clock=lambda: now[0])
    live.start("a moon"); live.finish(Image.new("RGB", (4, 4)))
    assert live.public()["done_ago"] == 0
    now[0] = 601
    assert live.expired()


def test_first_picture_allowed_when_injected_clock_starts_at_zero(tmp_path):
    studio = Imaginer(Ctrl(), api_key="fixture", path=str(tmp_path), clock=lambda: 0,
                      post=lambda *a: {"data": [{"b64_json": base64.b64encode(image_bytes()).decode()}]})
    assert studio.imagine("a moon")["imagined"]
    assert studio.status()["cooldown_s"] == 10


def test_on_wall_requires_effective_output_and_selected_mode(studio):
    studio.imagine("A new world")
    studio.ctrl.display_mode = "off"
    assert studio.status()["on_wall"] is False
    studio.ctrl.display_mode = "timer"
    assert studio.status()["on_wall"] is False
    studio.ctrl.display_mode = "imagine"
    assert studio.status()["on_wall"] is True
    studio.ctrl.apply({"mode": "off"})
    assert studio.status()["on_wall"] is False


def test_restore_acknowledges_selection_before_renderer_next_frame(studio):
    result = studio.imagine("A new world")
    studio.ctrl.apply({"mode": "clock"})
    studio.ctrl.display_mode = "clock"
    assert studio.show_again(result["id"])["shown"] is True
    assert studio.status()["on_wall"] is False
    studio.ctrl.display_mode = "imagine"
    assert studio.status()["on_wall"] is True
