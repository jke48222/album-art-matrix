"""Spotify OAuth receipts, provider failures and real control API boundaries."""
import copy
import json
import math
import os
import threading
import time
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import pytest
import requests

from brain.nowplaying import spotify
from brain.tests.test_control import api  # noqa: F401

CLIENT = "a" * 32
TOKENS = {"access_token": "private-access", "refresh_token": "private-refresh", "expires_in": 3600, "account_name": "A listener"}


class Response:
    def __init__(self, status=200, body=None, headers=None):
        self.status_code, self.body, self.headers = status, body, headers or {}
    def json(self):
        if isinstance(self.body, Exception):
            raise self.body
        return self.body


@pytest.fixture
def source(tmp_path, monkeypatch):
    monkeypatch.setattr(spotify, "TOKEN_PATH", str(tmp_path / "spotify.json"))
    return spotify.SpotifySource(CLIENT)


def linked(source):
    source.accept_tokens(TOKENS, client_id=CLIENT)
    return source


def current(playing=True):
    return {"currently_playing_type": "track", "is_playing": playing, "progress_ms": 1234,
            "item": {"id": "song", "name": "Nights", "duration_ms": 180000,
                     "artists": [{"name": "Frank Ocean"}], "album": {"name": "Blonde", "images": [{"url": "https://example.test/art"}]}}}


def test_token_commit_private_atomic_and_status_has_no_credentials(source):
    linked(source)
    assert os.stat(spotify.TOKEN_PATH).st_mode & 0o777 == 0o600
    assert source.status()["account_name"] == "A listener"
    assert source.status()["state"] == "ready"
    public = json.dumps(source.status())
    assert "private-access" not in public and "private-refresh" not in public
    assert "access_token" not in public and "refresh_token" not in public


@pytest.mark.parametrize("patch", [{"access_token": True}, {"refresh_token": []}, {"access_token": " "}, {"expires_in": True}, {"expires_in": math.nan}, {"expires_in": -1}, {"expires_in": 86401}])
def test_invalid_receipt_never_replaces_working_account(source, patch):
    linked(source)
    saved = open(spotify.TOKEN_PATH).read()
    with pytest.raises(ValueError):
        source.accept_tokens({**TOKENS, **patch})
    assert open(spotify.TOKEN_PATH).read() == saved and source.linked


def test_wrong_app_receipt_never_replaces_account(source):
    linked(source)
    saved = open(spotify.TOKEN_PATH).read()
    with pytest.raises(ValueError):
        source.accept_tokens(TOKENS, client_id="b" * 32)
    assert source.client_id == CLIENT and open(spotify.TOKEN_PATH).read() == saved


def test_storage_failure_preserves_memory_and_previous_file(source, monkeypatch):
    linked(source)
    old = copy.deepcopy(source._tokens)
    def fail(*args): raise PermissionError("disk unavailable")
    monkeypatch.setattr(spotify.os, "replace", fail)
    with pytest.raises(OSError): source.accept_tokens({**TOKENS, "access_token": "new"})
    assert source._tokens == old
    assert json.load(open(spotify.TOKEN_PATH))["access_token"] == TOKENS["access_token"]
    assert not list(Path(spotify.TOKEN_PATH).parent.glob(".spotify-*"))


def test_unlink_failure_does_not_lie_about_account(source, monkeypatch):
    linked(source)
    remove = spotify.os.remove
    def fail(path):
        if path == spotify.TOKEN_PATH: raise PermissionError("read only")
        return remove(path)
    monkeypatch.setattr(spotify.os, "remove", fail)
    with pytest.raises(OSError): source.unlink()
    assert source.linked


def test_refresh_preserves_rotating_credentials_name_and_sets_new_expiry(source, monkeypatch):
    linked(source)
    source._tokens["expires_at"] = 0
    monkeypatch.setattr(spotify.requests, "post", lambda *a, **k: Response(body={"access_token": "fresh", "expires_in": 3600}))
    assert source._access_token() == "fresh"
    assert source._tokens["refresh_token"] == TOKENS["refresh_token"]
    assert source.status()["account_name"] == "A listener"
    assert source._tokens["expires_at"] > 0


def test_unlink_during_refresh_cannot_resurrect_account(source, monkeypatch):
    linked(source)
    started, release = threading.Event(), threading.Event()
    def post(*args, **kwargs):
        started.set(); assert release.wait(2)
        return Response(body={**TOKENS, "access_token": "late"})
    monkeypatch.setattr(spotify.requests, "post", post)
    with ThreadPoolExecutor() as pool:
        future = pool.submit(source._refresh)
        try:
            assert started.wait(1)
            source.unlink()
            assert source.status()["state"] == "unlinked"
        finally: release.set()
        assert future.result(2) is False
    assert not source.linked and not os.path.exists(spotify.TOKEN_PATH)


def test_new_signin_during_refresh_is_not_overwritten(source, monkeypatch):
    linked(source)
    def post(*args, **kwargs):
        source.accept_tokens({**TOKENS, "access_token": "new-account"})
        return Response(body={**TOKENS, "access_token": "old-account"})
    monkeypatch.setattr(spotify.requests, "post", post)
    assert source._refresh() is False
    assert source._tokens["access_token"] == "new-account"


def test_expired_grant_requires_reconnect_without_poll_storm(source, monkeypatch):
    linked(source); source._tokens["expires_at"] = 0
    calls = []
    monkeypatch.setattr(spotify.requests, "post", lambda *a, **k: calls.append(1) or Response(400, {"error": "invalid_grant"}))
    for _ in range(4): assert source.get_current() is None
    assert calls == [1] and source.status()["state"] == "expired"
    assert not source.retry() and source.linked


def test_persistent_401_refreshes_once_without_recursion(source, monkeypatch):
    linked(source); gets, posts = [], []
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: gets.append(1) or Response(401, {}))
    monkeypatch.setattr(spotify.requests, "post", lambda *a, **k: posts.append(1) or Response(body=TOKENS))
    assert source.get_current() is None
    assert len(gets) == 2 and len(posts) == 1 and source.status()["state"] == "expired"


def test_refresh_outage_after_401_is_recoverable_not_expired(source, monkeypatch):
    linked(source)
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: Response(401, {}))
    monkeypatch.setattr(spotify.requests, "post", lambda *a, **k: Response(503, {}))
    assert source.get_current() is None
    assert source.status()["state"] == "unavailable" and source.status()["can_retry"]


@pytest.mark.parametrize("header", ["broken", "nan", "inf", "-1", "60"])
def test_rate_limit_is_bounded_and_respected(source, monkeypatch, header):
    linked(source); calls = []
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: calls.append(1) or Response(429, {}, {"Retry-After": header}))
    assert source.get_current() is None
    state = source.status()
    assert state["state"] == "rate_limited" and 0 < state["retry_after"] <= 60
    assert not state["can_retry"] and not source.retry()
    source.get_current(); assert len(calls) == 1


def test_refused_account_keeps_credentials_and_can_retry(source, monkeypatch):
    linked(source)
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: Response(403, {}))
    assert source.get_current() is None
    status = source.status()
    assert status["linked"] and status["state"] == "refused" and "app owner" in status["problem"]
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: Response(204))
    assert source.retry()
    wait_for_check(source)
    assert source.status()["state"] == "idle"


@pytest.mark.parametrize("playing,state", [(True, "playing"), (False, "paused")])
def test_playback_reports_real_pause_and_position(source, monkeypatch, playing, state):
    linked(source)
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: Response(body=current(playing)))
    track = source.get_current()
    assert track.is_playing is playing and track.progress_ms == 1234
    assert source.status()["state"] == state and source.status()["checked_at"]


def test_unlink_during_playback_request_discards_late_track(source, monkeypatch):
    linked(source)
    def get(*args, **kwargs):
        source.unlink(); return Response(body=current())
    monkeypatch.setattr(spotify.requests, "get", get)
    assert source.get_current() is None and source.status()["state"] == "unlinked"


def test_idle_and_provider_outage_are_distinct(source, monkeypatch):
    linked(source)
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: Response(204))
    assert source.get_current() is None and source.status()["state"] == "idle"
    def fail(*args, **kwargs): raise requests.Timeout("secret URL must not leak")
    monkeypatch.setattr(spotify.requests, "get", fail)
    assert source.get_current() is None and source.status()["state"] == "unavailable"
    assert "secret" not in source.status()["problem"]


def test_deleted_external_token_file_is_not_recreated(source, monkeypatch):
    linked(source); os.remove(spotify.TOKEN_PATH)
    def unexpected(*a, **k): raise AssertionError("unlinked must not query Spotify")
    monkeypatch.setattr(spotify.requests, "get", unexpected)
    assert source.get_current() is None and not source.linked


@pytest.fixture
def spotify_api(api, source):
    api.ctrl.spotify = source
    return api


def test_http_connect_status_and_disconnect_keep_app_id(spotify_api):
    api = spotify_api
    code, result = api.post("/spotify/tokens", {**TOKENS, "client_id": CLIENT})
    assert code == 200 and result["spotify"]["linked"]
    assert "private-" not in json.dumps(result)
    assert api.post("/spotify/unlink", {})[0] == 200
    status = api.get("/services")[1]["spotify"]
    assert status["client_id"] == CLIENT and not status["linked"]


def test_http_credential_mismatch_and_bad_receipt_preserve_account(spotify_api):
    api = spotify_api; linked(api.ctrl.spotify)
    old = copy.deepcopy(api.ctrl.spotify._tokens)
    assert api.post("/spotify/tokens", {**TOKENS, "client_id": "b" * 32})[0] == 409
    assert api.post("/spotify/tokens", {**TOKENS, "expires_in": "forever"})[0] == 400
    assert api.ctrl.spotify._tokens == old and api.ctrl.spotify.client_id == CLIENT


def test_http_tokens_require_explicit_app_setup(spotify_api):
    api = spotify_api; api.ctrl.spotify.set_client_id("")
    assert api.post("/spotify/tokens", {**TOKENS, "client_id": CLIENT})[0] == 409
    assert not api.ctrl.spotify.linked and not api.ctrl.spotify.client_id


@pytest.mark.parametrize("path", ["/spotify/tokens-extra", "/spotify/unlink-extra", "/spotify/retry-extra"])
def test_http_spotify_routes_are_exact(spotify_api, path):
    linked(spotify_api.ctrl.spotify)
    assert spotify_api.post(path, TOKENS)[0] == 404
    assert spotify_api.ctrl.spotify.linked


def test_http_persistence_failure_has_error_receipt(spotify_api, monkeypatch):
    linked(spotify_api.ctrl.spotify)
    def fail(*args, **kwargs): raise OSError("private path and token not public")
    monkeypatch.setattr(spotify_api.ctrl.spotify, "_save_tokens", fail)
    code, body = spotify_api.post("/spotify/tokens", TOKENS)
    assert code == 503 and "private" not in json.dumps(body)
    monkeypatch.setattr(spotify_api.ctrl.spotify, "unlink", fail)
    assert spotify_api.post("/spotify/unlink", {})[0] == 503


def test_http_retry_respects_provider_deadline(spotify_api, monkeypatch):
    source = linked(spotify_api.ctrl.spotify)
    monkeypatch.setattr(spotify.requests, "get", lambda *a, **k: Response(429, {}, {"Retry-After": "60"}))
    source.get_current()
    assert spotify_api.post("/spotify/retry", {})[0] == 409
    source._backoff_until = 0
    assert spotify_api.post("/spotify/retry", {})[0] == 200
    wait_for_check(source)


def wait_for_check(source):
    deadline = time.monotonic() + 2
    while source._checking and time.monotonic() < deadline:
        time.sleep(.005)
    assert not source._checking


def test_manual_check_runs_without_source_chain_and_coalesces(source, monkeypatch):
    linked(source)
    started, release = threading.Event(), threading.Event()
    calls = []
    def get(*args, **kwargs):
        calls.append(1); started.set(); assert release.wait(2)
        return Response(204)
    monkeypatch.setattr(spotify.requests, "get", get)
    try:
        assert source.retry()
        assert started.wait(1)
        assert source.status()["state"] == "checking"
        assert not source.retry()
        assert source.get_current() is None  # normal polling cannot duplicate the check
        source.unlink()  # status and disconnect stay responsive during I/O
    finally:
        release.set()
    wait_for_check(source)
    assert calls == [1] and not source.linked and source.status()["state"] == "unlinked"


def test_old_playback_status_does_not_claim_to_follow_current_music(source):
    linked(source)
    source._state, source._checked_at = "playing", time.time() - 300
    assert source.status()["state"] == "ready" and source.linked


@pytest.fixture
def configured_api(spotify_api, tmp_path, monkeypatch):
    from brain import services
    monkeypatch.setattr(services, "PATH", str(tmp_path / "services.json"))
    store = services.Services({"spotify": {"client_id": CLIENT}})
    store.update({"lastfm": {"user": "existing-listener"}})
    spotify_api.ctrl.services_store = store
    linked(spotify_api.ctrl.spotify)
    return spotify_api


def test_service_save_failure_keeps_every_value_and_secret_private(configured_api, monkeypatch):
    from brain import services
    api = configured_api
    old = copy.deepcopy(api.ctrl.services_store.data)
    old_file = Path(services.PATH).read_bytes()
    def fail(*args): raise OSError("private credentials must not escape")
    monkeypatch.setattr(api.ctrl.services_store, "_save", fail)
    code, body = api.post("/services", {"lastfm": {"user": "changed-listener"}})
    assert code == 503 and "private" not in json.dumps(body)
    assert api.ctrl.services_store.data == old and Path(services.PATH).read_bytes() == old_file


def test_client_id_service_save_failure_restores_detached_tokens(configured_api, monkeypatch):
    from brain import services
    api = configured_api
    old = copy.deepcopy(api.ctrl.spotify._tokens)
    saved = Path(spotify.TOKEN_PATH).read_bytes()
    old_file = Path(services.PATH).read_bytes()
    def fail(*args): raise OSError("disk full")
    monkeypatch.setattr(api.ctrl.services_store, "_save", fail)
    code, _ = api.post("/services", {"spotify": {"client_id": "b" * 32}, "lastfm": {"user": "changed-listener"}})
    assert code == 503
    assert api.ctrl.services_store.get("spotify", "client_id") == CLIENT
    assert api.ctrl.services_store.get("lastfm", "user") == "existing-listener"
    assert api.ctrl.spotify.client_id == CLIENT and api.ctrl.spotify._tokens == old
    assert Path(spotify.TOKEN_PATH).read_bytes() == saved and Path(services.PATH).read_bytes() == old_file


def test_client_id_detach_failure_never_commits_new_services(configured_api, monkeypatch):
    from brain import services
    api = configured_api
    old_file = Path(services.PATH).read_bytes()
    replace = spotify.os.replace
    def fail_tokens(source, destination):
        if source == spotify.TOKEN_PATH: raise PermissionError("locked token directory")
        return replace(source, destination)
    monkeypatch.setattr(spotify.os, "replace", fail_tokens)
    assert api.post("/services", {"spotify": {"client_id": "b" * 32}})[0] == 503
    assert api.ctrl.spotify.client_id == CLIENT and api.ctrl.spotify.linked
    assert api.ctrl.services_store.get("spotify", "client_id") == CLIENT
    assert Path(services.PATH).read_bytes() == old_file


def test_explicit_client_id_change_commits_and_detaches_old_account(configured_api):
    from brain import services
    api = configured_api
    code, result = api.post("/services", {"spotify": {"client_id": "b" * 32}})
    assert code == 200 and not result["spotify"]["linked"]
    assert api.ctrl.spotify.client_id == "b" * 32
    assert api.ctrl.services_store.get("spotify", "client_id") == "b" * 32
    assert json.loads(Path(services.PATH).read_text())["spotify"]["client_id"] == "b" * 32
    assert not Path(spotify.TOKEN_PATH).exists()
    assert not list(Path(spotify.TOKEN_PATH).parent.glob(".spotify-detached-*"))
    assert os.stat(services.PATH).st_mode & 0o777 == 0o600


def test_service_store_final_replace_failure_keeps_memory_and_disk(configured_api, monkeypatch):
    from brain import services
    api = configured_api
    old = copy.deepcopy(api.ctrl.services_store.data)
    old_file = Path(services.PATH).read_bytes()
    replace = services.os.replace
    def fail_service(source, destination):
        if destination == services.PATH: raise OSError("no space")
        return replace(source, destination)
    monkeypatch.setattr(services.os, "replace", fail_service)
    assert api.post("/services", {"spotify": {"client_id": "b" * 32}})[0] == 503
    assert api.ctrl.services_store.data == old and Path(services.PATH).read_bytes() == old_file
    assert api.ctrl.spotify.client_id == CLIENT and api.ctrl.spotify.linked
    assert Path(spotify.TOKEN_PATH).exists()
