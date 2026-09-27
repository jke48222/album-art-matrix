"""Connection ownership, credential privacy, and poster checks. No paid calls."""
import base64
import io
import json
import threading
import time

import pytest
import requests
from PIL import Image

from brain.posters import Posters, PosterSource
from brain.imagine import Imaginer
from brain.tests.test_imagine import Ctrl
from brain.tests.test_posters import TV, NOTHING


def wait_for(predicate):
    deadline = time.monotonic() + 3
    while not predicate() and time.monotonic() < deadline:
        time.sleep(0.005)
    assert predicate()


def make_posters(tmp_path, fetch, clock=None):
    return Posters(api_key="a" * 32, path=str(tmp_path / "posters.json"), fetch=fetch, clock=clock)


def test_check_verifies_without_writing_poster_history(tmp_path):
    calls = []
    def fetch(path, params):
        calls.append((path, params))
        return {"images": {"base_url": "https://image.tmdb.org/"}}
    posters = make_posters(tmp_path, fetch)
    assert posters.status()["state"] == "saved" and not posters.status()["verified"]
    assert posters.check()
    wait_for(lambda: not posters.status()["checking"])
    assert calls == [("/configuration", {})]
    assert posters.status()["verified"] and posters.status()["state"] == "ready"
    assert posters.count == 0 and posters.last is None
    assert not posters.check()  # Coalescing applies after completion as well.


def test_title_check_records_match_without_a_wall(tmp_path):
    posters = make_posters(tmp_path, lambda *_: TV)
    assert posters.check("Severance")
    wait_for(lambda: not posters.status()["checking"])
    state = posters.status()
    assert state["state"] == "matched" and state["verified"]
    assert state["last"]["poster"].startswith("https://image.tmdb.org/")
    assert state["last"]["id"] == 95396
    assert state["last"]["overview"]


@pytest.mark.parametrize("title", ["", " ", "x" * 241, 45, {}, "Netflix"])
def test_invalid_lookup_does_not_start(tmp_path, title):
    calls = []
    posters = make_posters(tmp_path, lambda *_: calls.append(1))
    assert not posters.check(title)
    assert not calls and posters.status()["state"] == "saved"


def test_key_removed_during_check_cannot_restore_verified_state(tmp_path):
    started, finish = threading.Event(), threading.Event()
    def fetch(*_):
        started.set()
        assert finish.wait(3)
        return {"images": {}}
    posters = make_posters(tmp_path, fetch)
    assert posters.check() and started.wait(3)
    posters.configure(api_key="")
    finish.set()
    wait_for(lambda: not posters.status()["checking"])
    assert not posters.status()["key_set"] and not posters.status()["verified"]
    assert posters.status()["state"] == "unlinked"


def test_replaced_key_cannot_publish_old_lookup_or_cache(tmp_path):
    started, finish = threading.Event(), threading.Event()
    def fetch(*_):
        started.set()
        assert finish.wait(3)
        return TV
    posters = make_posters(tmp_path, fetch)
    worker = threading.Thread(target=lambda: posters.lookup("Severance"))
    worker.start()
    assert started.wait(3)
    posters.configure(api_key="b" * 32)
    finish.set(); worker.join(3)
    assert not worker.is_alive()
    assert posters.last is None and posters.count == 0 and not posters._cache
    assert posters.status()["state"] == "saved"


def test_same_show_recovers_from_temporary_failure(tmp_path):
    clock, calls = [100.0], []
    def fetch(*_):
        calls.append(1)
        if len(calls) == 1:
            raise requests.ConnectionError("offline")
        return TV
    posters = make_posters(tmp_path, fetch, clock=lambda: clock[0])
    class Mac:
        show = {"title": "Severance", "seen": 100.0}
    source = PosterSource(Mac(), posters, clock=lambda: clock[0])
    assert source.get_current() is None
    assert source.get_current() is None and len(calls) == 1
    clock[0] += 16
    assert source.get_current().title == "Severance"
    assert len(calls) == 2


def test_key_replacement_invalidates_source_memo(tmp_path):
    calls = []
    posters = make_posters(tmp_path, lambda *_: calls.append(1) or TV)
    class Mac:
        show = {"title": "Severance"}
    source = PosterSource(Mac(), posters)
    assert source.get_current().title == "Severance"
    posters.configure(api_key="")
    assert source.get_current() is None
    posters.configure(api_key="b" * 32)
    assert source.get_current().title == "Severance"
    assert source._last[0][-1] == posters.generation


def test_rejection_does_not_expose_key_or_cache_as_miss(tmp_path, capsys):
    secret = "a" * 32
    def fetch(*_):
        raise PermissionError("https://api.themoviedb.org/3?api_key=" + secret)
    posters = make_posters(tmp_path, fetch)
    assert posters.lookup("Severance") is None
    assert posters.status()["state"] == "refused"
    assert not posters._cache
    assert secret not in json.dumps(posters.status()) + capsys.readouterr().out


@pytest.mark.parametrize("response", [[], None, {"results": None}, {"results": "bad"}])
def test_malformed_tmdb_response_is_not_a_permanent_miss(tmp_path, response):
    posters = make_posters(tmp_path, lambda *_: response)
    assert posters.lookup("Severance") is None
    assert posters.status()["state"] == "unavailable" and not posters._cache


def test_rate_limit_honors_bounded_retry_after(tmp_path):
    response = requests.Response(); response.status_code = 429
    response.headers["Retry-After"] = "999999"
    def fetch(*_):
        raise requests.HTTPError(response=response)
    posters = make_posters(tmp_path, fetch, clock=lambda: 100)
    posters.lookup("Severance")
    assert posters.status()["state"] == "rate_limited"
    assert posters.status()["retry_after"] == 3600
    assert not posters.check()


def make_image(tmp_path, **kw):
    buffer = io.BytesIO(); Image.new("RGB", (12, 12), "green").save(buffer, "PNG")
    def post(*_):
        return {"data": [{"b64_json": base64.b64encode(buffer.getvalue()).decode()}]}
    return Imaginer(Ctrl(), api_key="sk-fixture-private-key-12345", path=str(tmp_path / "images"), post=post, **kw)


def test_provider_switch_never_reuses_another_service_key(tmp_path):
    studio = make_image(tmp_path)
    studio.model_used = "gpt-image-1"
    studio.verified = True
    studio.configure(provider="google")
    assert not studio.api_key and not studio.ready
    assert not studio.verified and studio.model_used is None
    assert studio.model == "imagen-4.0-ultra-generate-001"
    studio.configure(api_key="a-google-key", model="custom-google-model")
    studio.configure(provider="openai")
    assert not studio.api_key and studio.model == "gpt-image-2"


def test_replacing_key_clears_previous_verification(tmp_path):
    studio = make_image(tmp_path)
    assert studio.imagine("a tree")["imagined"]
    assert studio.status()["verified"]
    studio.configure(api_key="replacement-key")
    assert studio.status()["verified"] is False
    assert studio.status()["model_used"] is None
    assert studio.listing() and studio.last


def test_pending_settings_are_visible_without_exposing_credentials(tmp_path):
    studio = make_image(tmp_path)
    assert studio._take("a tree") is None
    studio.configure(provider="google", api_key="private-next-key")
    status = studio.status()
    assert status["pending_change"] and status["pending_provider"] == "google"
    assert "private-next-key" not in json.dumps(status)
    assert status["provider"] == "openai"
    studio._finished()
    assert studio.provider == "google" and studio.api_key == "private-next-key"
    assert not studio.status()["pending_change"]


def test_provider_error_does_not_publish_key(tmp_path, capsys):
    studio = make_image(tmp_path)
    secret = studio.api_key
    def post(*_):
        raise RuntimeError("https://example.com?api_key=" + secret)
    studio._post = post
    result = studio.imagine("a tree")
    serialized = json.dumps(result) + json.dumps(studio.status()) + capsys.readouterr().out
    assert secret not in serialized and "https://example.com" not in serialized
    assert result["error"] and studio.status()["problem"]


@pytest.mark.parametrize("code", [400, 401, 403, 404, 429, 500])
def test_http_provider_messages_are_sanitized(code):
    class Response:
        status_code = code
        def json(self):
            return {"error": {"message": "Secret sk-real-secret was rejected; https://private.invalid"}}
    error = str(Imaginer._http_error(Response()))
    assert "sk-real-secret" not in error and "private.invalid" not in error
    assert error.startswith(str(code))


def test_stream_is_closed_when_authentication_is_rejected(tmp_path, monkeypatch):
    studio = make_image(tmp_path)
    class Response:
        status_code = 401
        closed = False
        def close(self):
            self.closed = True
    response = Response()
    monkeypatch.setattr("brain.imagine.requests.post", lambda *args, **kwargs: response)
    with pytest.raises(RuntimeError, match="401"):
        list(studio._http_stream("https://example.invalid", {}, {}))
    assert response.closed


def test_check_joining_automatic_lookup_cannot_leave_checking_state_stuck(tmp_path):
    started, finish = threading.Event(), threading.Event()
    def fetch(*_):
        started.set()
        assert finish.wait(3)
        return TV
    posters = make_posters(tmp_path, fetch)
    worker = threading.Thread(target=lambda: posters.lookup("Severance"))
    worker.start()
    assert started.wait(3)
    try:
        assert posters.check("Severance")
        wait_for(lambda: not posters.status()["checking"])
        assert posters.status()["state"] != "checking"
    finally:
        finish.set(); worker.join(3)
    assert posters.status()["state"] == "matched"
