"""Discovery receipts, ownership, and real provider-boundary regressions."""
import base64
import io
import time
from types import SimpleNamespace

import pytest
from PIL import Image

from brain import show
from brain.ask import Asker
from brain.control import ControlState


@pytest.fixture
def finder():
    value = show.Shower(ControlState(frame_len=64 * 64 * 3))
    yield value
    if value._timer is not None:
        value._timer.cancel()


def album():
    return {"title": "Signal", "artist": "North", "album": "Signal", "art_url": "https://example.test/sleeve.png", "score": 1.0}


@pytest.fixture
def sleeve(monkeypatch):
    image = Image.new("RGB", (128, 96), (33, 91, 137))
    monkeypatch.setattr(show, "find_art", lambda query: album())
    monkeypatch.setattr(show, "fetch_art", lambda url: image)
    return image


def test_receipt_is_exact_rendered_wall_rgb_and_later_selection_is_not_claimed(finder, sleeve):
    result = finder.show("Signal by North", "cover")
    png = Image.open(io.BytesIO(base64.b64decode(result["preview_png"]))).convert("RGB")
    assert png.size == (64, 64)
    assert png.tobytes() == finder.ctrl.frame_override
    assert result["active"] and result["shown"]
    finder.ctrl.apply({"mode": "clock"})
    assert finder.discovery_status()["last"]["active"] is False
    assert finder.discovery_status()["last"]["preview_png"] == result["preview_png"]


def test_old_expiry_cannot_remove_a_new_drawing(finder, sleeve):
    finder.show("Signal", "cover")
    old_sequence = finder._frame_seq
    finder.ctrl.frame_override = bytes([7] * (64 * 64 * 3))
    finder.ctrl.shown_seq += 1
    finder._until = 0
    finder._take_down(old_sequence)
    assert finder.ctrl.get()["mode"] == "frame"
    assert finder.ctrl.frame_override[0] == 7


def test_new_show_cancels_old_expiry_preserves_original_face(finder, sleeve):
    finder.ctrl.apply({"mode": "clock"})
    finder.show("Signal", "cover")
    old_sequence = finder._frame_seq
    finder.show("North", "cover")
    finder._until = 0
    finder._take_down(old_sequence)
    assert finder.ctrl.get()["mode"] == "frame"
    finder._take_down(finder._frame_seq)
    assert finder.ctrl.get()["mode"] == "clock"


def test_failure_never_replaces_last_valid_result(finder, sleeve, monkeypatch):
    result = finder.show("Signal", "cover")
    monkeypatch.setattr(show, "find_art", lambda query: None)
    failed = finder.show("Missing", "cover")
    assert "error" in failed
    assert finder.discovery_status()["last"]["id"] == result["id"]
    assert finder.discovery_status()["problem"] == failed["error"]
    assert finder.earworm_status()["problem"] is None


@pytest.mark.parametrize("query,kind", [("", "cover"), ("x" * 501, "cover"), ([], "cover"), ("hi", "surprise")])
def test_bad_search_input_is_rejected_before_provider_work(finder, query, kind):
    assert finder.show(query, kind)["code"] == 400


def test_busy_discovery_does_not_start_a_second_search(finder, monkeypatch):
    monkeypatch.setattr(show, "find_art", lambda query: pytest.fail("must not call provider"))
    with finder._work_lock:
        assert finder.show("Signal", "cover")["code"] == 409
        assert finder.play("Signal")["code"] == 409
        assert finder.earworm("some words")["code"] == 409


def test_earworm_survives_other_discoveries_and_reshows_without_ai_call(finder, sleeve):
    calls = []
    finder.asker = SimpleNamespace(ready=True, problem=None, earworm=lambda words: calls.append(words) or {
        "title": "Signal", "artist": "North", "confidence": .91, "alternatives": []})
    found = finder.earworm("the signal in the sky")
    assert found["shown"] and found["seconds"] == 600
    assert Image.open(io.BytesIO(base64.b64decode(found["preview_png"]))).size == (64, 64)
    finder.show("Another sleeve", "cover")
    assert finder.earworm_status()["last"]["id"] == found["id"]
    assert finder.earworm_status()["last"]["active"] is False
    reshown = finder.show_earworm(found["id"])
    assert reshown["active"] and reshown["id"] == found["id"]
    assert calls == ["the signal in the sky"]
    assert finder.show_earworm("stale-result")["code"] == 409


def test_no_sleeve_is_a_song_result_not_false_wall_success(finder, monkeypatch):
    finder.asker = SimpleNamespace(ready=True, problem=None, earworm=lambda words: {
        "title": "Signal", "artist": "North", "confidence": .7, "alternatives": []})
    monkeypatch.setattr(show, "find_art", lambda query: None)
    found = finder.earworm("a remembered line")
    assert found["title"] == "Signal" and found["shown"] is False and found["active"] is False
    assert "preview_png" not in found
    assert finder.show_earworm(found["id"])["code"] == 502


def test_provider_error_is_preserved_for_reopened_page(finder):
    finder.asker = SimpleNamespace(ready=True, problem="Service unavailable", earworm=lambda words: None)
    assert finder.earworm("words")["error"] == "Service unavailable"
    assert finder.earworm_status()["problem"] == "Service unavailable"
    assert finder.earworm_status()["pending"] is False


def test_video_options_cannot_be_injected_by_search_words(finder, monkeypatch):
    commands = []
    finder.ctrl.video = object()
    monkeypatch.setattr(show.ytdlp, "binary", lambda: "/usr/bin/yt-dlp")
    monkeypatch.setattr(show.subprocess, "run", lambda command, **kwargs:
                        commands.append(command) or SimpleNamespace(returncode=1, stdout="garbage"))
    assert "error" in finder.play("--exec malicious")
    assert commands[0][-2:] == ["--", "--exec malicious"]


def test_provider_exception_releases_discovery_lock(finder, monkeypatch):
    def fail(query):
        raise RuntimeError("offline")
    monkeypatch.setattr(show, "find_art", fail)
    assert finder.show("Signal", "cover")["code"] == 502
    assert finder.pending is None
    assert finder._work_lock.acquire(blocking=False)
    finder._work_lock.release()


def test_search_finishing_after_off_cannot_turn_the_wall_back_on(finder, sleeve, monkeypatch):
    finder.ctrl.apply({"mode": "clock"})
    def slow_fetch(url):
        finder.ctrl.apply({"mode": "off"})
        return sleeve
    monkeypatch.setattr(show, "fetch_art", slow_fetch)
    result = finder.show("Signal", "cover")
    assert result["code"] == 409
    assert finder.ctrl.get()["mode"] == "off"
    assert finder.last_show is None


def test_earworm_finishing_after_new_face_does_not_replace_it(finder, sleeve, monkeypatch):
    def name_song(words):
        finder.ctrl.apply({"mode": "clock"})
        return {"title": "Signal", "artist": "North", "confidence": .91, "alternatives": []}
    finder.asker = SimpleNamespace(ready=True, problem=None, earworm=name_song)
    result = finder.earworm("words")
    assert result["code"] == 409
    assert finder.ctrl.get()["mode"] == "clock"


def fake_asker(output=None, failure=None):
    value = Asker(SimpleNamespace(), api_key="test-key")
    def parse(**kwargs):
        if failure:
            raise failure
        model = kwargs["output_format"]
        return SimpleNamespace(parsed_output=model(**output))
    value._client = SimpleNamespace(messages=SimpleNamespace(parse=parse))
    return value


def test_earworm_provider_metadata_is_trimmed_and_alternatives_are_unique():
    value = fake_asker({"title": " Signal ", "artist": " North ", "confidence": .9,
                        "alternatives": [{"title": "Signal", "artist": "North"},
                                         {"title": "Else", "artist": "Other"},
                                         {"title": "Else", "artist": "Other"}]})
    found = value.earworm("words")
    assert found == {"title": "Signal", "artist": "North", "confidence": .9,
                     "alternatives": [{"title": "Else", "artist": "Other"}]}
    assert not value.pending and value.problem is None


@pytest.mark.parametrize("confidence", [-.1, 1.1, float("nan"), float("inf")])
def test_provider_invalid_confidence_fails_without_sticking_busy(confidence):
    value = fake_asker({"title": "Signal", "artist": "North", "confidence": confidence, "alternatives": []})
    assert value.earworm("words") is None
    assert value.problem and not value.pending
    assert value._ask_lock.acquire(blocking=False)
    value._ask_lock.release()


def test_provider_can_say_no_match_instead_of_inventing_a_song():
    value = fake_asker({"title": "", "artist": "", "confidence": 0, "alternatives": []})
    assert value.earworm("unrecognizable") is None
    assert "No confident match" in value.problem


def test_earworm_does_not_overlap_an_existing_ask_request():
    value = fake_asker(failure=AssertionError("must not call provider"))
    with value._ask_lock:
        assert value.earworm("words") is None
        assert "finishing another request" in value.problem
