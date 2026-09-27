"""Last.fm reader: honest status, private errors and account-generation races."""
import json
import threading

import pytest
import requests

import brain.nowplaying.lastfm as module
from brain.nowplaying.lastfm import LastfmSource

KEY = "a" * 32
ART = "https://lastfm.freetls.fastly.net/i/u/300x300/test-cover.png"


class Response:
    def __init__(self, payload=None, code=200, headers=None):
        self.payload = payload
        self.status_code = code
        self.headers = headers or {}

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(f"private URL ?api_key={KEY}")

    def json(self):
        if isinstance(self.payload, Exception):
            raise self.payload
        return self.payload


def track(*, current=True, title="Prism Studies", artist="Tessera Ensemble", at="1700000000", art=ART):
    result = {"name": title, "artist": {"#text": artist}, "album": {"#text": "Night Signals"},
              "image": [{"#text": art, "size": "extralarge"}]}
    if current:
        result["@attr"] = {"nowplaying": "true"}
    else:
        result["date"] = {"uts": at}
    return result


@pytest.fixture
def source(monkeypatch):
    monkeypatch.setattr(module, "_itunes_art", lambda *args: None)
    return LastfmSource(KEY, "test-listener")


def respond(monkeypatch, payload=None, code=200, headers=None):
    response = Response(payload, code, headers)
    monkeypatch.setattr(module.requests, "get", lambda *args, **kwargs: response)
    return response


def test_no_credentials_makes_no_request(monkeypatch):
    monkeypatch.setattr(module.requests, "get", lambda *a, **k: pytest.fail("network requested"))
    source = LastfmSource()
    assert source.get_current() is None
    assert source.status()["state"] == "unconfigured"
    assert not source.retry()
    source.configure(api_key=KEY)
    assert source.status()["state"] == "unlinked"
    source.configure(api_key="", user="listener")
    assert source.status()["state"] == "needs_key"


def test_current_track_has_no_invented_position_and_preserves_original_art(source, monkeypatch):
    monkeypatch.setattr(module, "_itunes_art", lambda *args: pytest.fail("replaced actual source art"))
    observed = {}
    def get(url, **kwargs):
        observed.update(url=url, **kwargs)
        return Response({"recenttracks": {"track": [track(), track(current=False, title="Earlier Song")]}})
    monkeypatch.setattr(module.requests, "get", get)
    now = source.get_current()
    assert now.title == "Prism Studies" and now.is_playing
    assert now.progress_ms is None and now.duration_ms is None and now.art_url == ART
    assert observed["url"] == module.API and observed["timeout"] == 10
    assert observed["params"]["limit"] == 2
    status = source.status()
    assert status["state"] == "playing"
    assert status["current"]["title"] == now.title
    assert status["last_listen"]["title"] == "Earlier Song"
    assert status["checked_at"] > 0
    assert KEY not in json.dumps(status)


def test_completed_scrobble_never_drives_wall(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": [track(current=False)]}})
    assert source.get_current() is None
    assert source.status()["state"] == "idle"
    assert source.status()["current"] is None
    assert source.status()["last_listen"]["at"] == 1700000000


@pytest.mark.parametrize("flag", [None, "false", False, "TRUE", 1, "1"])
def test_only_explicit_nowplaying_marker_counts(source, monkeypatch, flag):
    item = track()
    item["@attr"] = {"nowplaying": flag}
    respond(monkeypatch, {"recenttracks": {"track": [item]}})
    now = source.get_current()
    assert now is None


def test_single_track_object_is_supported(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": track()}})
    assert source.get_current().title == "Prism Studies"


def test_empty_valid_feed_is_idle(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": []}})
    assert source.get_current() is None
    assert source.status()["state"] == "idle"
    assert source.status()["last_listen"] is None


@pytest.mark.parametrize("payload", [None, [], {}, {"recenttracks": None},
                                     {"recenttracks": {"track": None}}, {"recenttracks": {"track": [None]}},
                                     {"recenttracks": {"track": [{"name": "missing artist"}]}},
                                     ValueError(f"response with key {KEY}")])
def test_malformed_response_is_unavailable_never_idle(source, monkeypatch, payload):
    respond(monkeypatch, payload)
    assert source.get_current() is None
    assert source.status()["state"] == "unavailable"
    assert KEY not in json.dumps(source.status())


@pytest.mark.parametrize("code,state", [(4, "refused"), (9, "refused"), (10, "refused"), (13, "refused"),
                                       (17, "refused"), (26, "refused"), (6, "not_found"), (7, "not_found"),
                                       (11, "unavailable"), (16, "unavailable"), (8, "unavailable"), (29, "rate_limited")])
def test_api_error_statuses_are_sanitized(source, monkeypatch, code, state):
    respond(monkeypatch, {"error": code, "message": f"server reflected key {KEY}"})
    assert source.get_current() is None
    status = source.status()
    assert status["state"] == state
    assert KEY not in json.dumps(status)
    assert status["problem"] and status["retry_after"] > 0 and not status["can_retry"]


@pytest.mark.parametrize("code,state", [(401, "refused"), (403, "refused"), (500, "unavailable"), (503, "unavailable")])
def test_http_failures_hide_request_urls(source, monkeypatch, code, state):
    respond(monkeypatch, code=code)
    assert source.get_current() is None
    assert source.status()["state"] == state
    assert KEY not in json.dumps(source.status())


@pytest.mark.parametrize("header,seconds", [(None, 60), ("12", 12), ("NaN", 60), ("inf", 60), ("-1", 5), ("9000", 3600), ("tomorrow", 60)])
def test_rate_limit_honors_bounded_retry_after(source, monkeypatch, header, seconds):
    respond(monkeypatch, code=429, headers={"Retry-After": header})
    assert source.get_current() is None
    assert source.status()["state"] == "rate_limited"
    assert source.status()["retry_after"] == pytest.approx(seconds, abs=0.2)
    assert not source.retry()


def test_network_exception_is_sanitized(source, monkeypatch):
    def fail(*args, **kwargs):
        raise requests.ConnectionError(f"failed to connect {module.API}?api_key={KEY}")
    monkeypatch.setattr(module.requests, "get", fail)
    assert source.get_current() is None
    assert KEY not in json.dumps(source.status())
    assert source.status()["state"] == "unavailable"


def test_cache_and_stale_status_do_not_claim_live_forever(source, monkeypatch):
    clock = [100.0]
    monkeypatch.setattr(module.time, "monotonic", lambda: clock[0])
    response = respond(monkeypatch, {"recenttracks": {"track": [track()]}})
    result = source.get_current()
    response.payload = {"recenttracks": {"track": []}}
    assert source.get_current() is result
    clock[0] += 31
    assert source.status()["state"] == "ready" and source.status()["current"] is None
    assert source.get_current() is None
    assert source.status()["state"] == "idle"


def test_error_clears_previous_playing_claim(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": [track()]}})
    assert source.get_current()
    source._asked_at -= 6
    respond(monkeypatch, {"error": 11})
    assert source.get_current() is None
    assert source.status()["current"] is None
    assert source.status()["state"] == "unavailable"


@pytest.mark.parametrize("art", ["http://untrusted/art", "file:///private/key", "https://user:password@example.com/art", "javascript:alert(1)"])
def test_unsafe_art_not_exposed(source, monkeypatch, art):
    respond(monkeypatch, {"recenttracks": {"track": [track(art=art)]}})
    assert source.get_current().art_url is None
    assert source.status()["current"]["art_url"] is None


def test_art_fallback_only_when_source_missing(source, monkeypatch):
    calls = []
    monkeypatch.setattr(module, "_itunes_art", lambda *args: calls.append(args) or ART)
    respond(monkeypatch, {"recenttracks": {"track": [track(art="")]}})
    assert source.get_current().art_url == ART
    assert calls == [("Tessera Ensemble Night Signals", "album")]


def test_reconfiguration_discards_late_account_result_and_art_cache(source, monkeypatch):
    entered, release = threading.Event(), threading.Event()
    def get(*args, **kwargs):
        if kwargs["params"]["user"] == "test-listener":
            entered.set()
            assert release.wait(2)
            return Response({"recenttracks": {"track": [track(title="Old Account")]}})
        return Response({"recenttracks": {"track": [track(title="New Account")]}})
    monkeypatch.setattr(module.requests, "get", get)
    old = []
    thread = threading.Thread(target=lambda: old.append(source.get_current()))
    thread.start()
    assert entered.wait(2)
    source.configure(user="new-listener")
    assert source.get_current().title == "New Account"
    release.set(); thread.join(2)
    assert old == [None]
    assert source.status()["current"]["title"] == "New Account"
    assert source._art_key[-1] == "New Account"


def test_unlink_during_request_stays_disconnected(source, monkeypatch):
    entered, release = threading.Event(), threading.Event()
    def get(*args, **kwargs):
        entered.set(); assert release.wait(2)
        return Response({"recenttracks": {"track": [track()]}})
    monkeypatch.setattr(module.requests, "get", get)
    result = []
    thread = threading.Thread(target=lambda: result.append(source.get_current()))
    thread.start(); assert entered.wait(2)
    source.configure(user="")
    release.set(); thread.join(2)
    assert result == [None]
    assert source.status()["state"] == "unlinked"
    assert source.status()["current"] is None and source.status()["last_listen"] is None
    assert source.status()["key_set"] is True


def test_retry_is_nonblocking_and_coalesces(source, monkeypatch):
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    calls = []
    def get(*args, **kwargs):
        calls.append(1); entered.set(); assert release.wait(2)
        return Response({"recenttracks": {"track": [track()]}})
    monkeypatch.setattr(module.requests, "get", get)
    finish = source._finish
    def wrapped(flight):
        try: return finish(flight)
        finally: finished.set()
    monkeypatch.setattr(source, "_finish", wrapped)
    assert source.retry()
    assert entered.wait(2)
    assert source.status()["state"] == "checking"
    assert not source.retry()
    assert source.get_current() is None
    release.set(); assert finished.wait(2)
    assert calls == [1]
    assert source.status()["state"] == "playing"


def test_same_configuration_keeps_current_verified_state(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": [track()]}})
    now = source.get_current()
    source.configure(KEY, "test-listener")
    assert source.get_current() is now


@pytest.mark.parametrize("at", ["nonsense", "-1", "9999999999999999999", None, "nan"])
def test_invalid_history_timestamp_is_omitted(source, monkeypatch, at):
    respond(monkeypatch, {"recenttracks": {"track": [track(current=False, at=at)]}})
    assert source.get_current() is None
    assert source.status()["last_listen"]["at"] is None


def test_public_status_returns_history_copy(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": [track(current=False)]}})
    source.get_current()
    status = source.status(); status["last_listen"]["title"] = "tampered"
    assert source.status()["last_listen"]["title"] == "Prism Studies"

# Exercise the production HTTP routing too: no private key may escape services.
from brain.tests.test_control import api  # noqa: E402, F401


def test_services_api_exposes_reader_status_without_key(api, source, monkeypatch):
    api.ctrl.lastfm = source
    respond(monkeypatch, {"recenttracks": {"track": [track()]}})
    source.get_current()
    code, body = api.get("/services")
    assert code == 200 and body["lastfm"]["state"] == "playing"
    assert body["lastfm"]["current"]["title"] == "Prism Studies"
    assert KEY not in json.dumps(body)
    assert "api_key" not in body["lastfm"]


def test_retry_route_requires_available_source(api):
    assert api.post("/lastfm/retry", {})[0] == 404
    api.ctrl.lastfm = LastfmSource()
    assert api.post("/lastfm/retry", {})[0] == 409


def test_retry_route_coalesces_and_does_not_block_http(api, source, monkeypatch):
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    def get(*args, **kwargs):
        entered.set(); assert release.wait(3)
        return Response({"recenttracks": {"track": [track()]}})
    monkeypatch.setattr(module.requests, "get", get)
    finish = source._finish
    def wrapped(flight):
        try: return finish(flight)
        finally: finished.set()
    monkeypatch.setattr(source, "_finish", wrapped)
    api.ctrl.lastfm = source
    try:
        code, body = api.post("/lastfm/retry", {})
        assert code == 200 and body["lastfm"]["state"] == "checking"
        assert entered.wait(2)
        assert api.post("/lastfm/retry", {})[0] == 409
    finally:
        release.set()
    assert finished.wait(2)
    assert api.get("/services")[1]["lastfm"]["state"] == "playing"


@pytest.mark.parametrize("path", ["/lastfm/retry-extra", "/lastfm/retry/", "/lastfm/retry?force=true"])
def test_retry_route_is_exact(api, path):
    assert api.post(path, {})[0] == 404


def test_retry_route_rejects_invalid_json(api, source):
    api.ctrl.lastfm = source
    assert api.post("/lastfm/retry", raw=b"{")[0] == 400


def test_changed_source_art_replaces_cached_art(source, monkeypatch):
    respond(monkeypatch, {"recenttracks": {"track": [track()]}})
    assert source.get_current().art_url == ART
    source._asked_at -= 6
    fresh_art = "https://lastfm.freetls.fastly.net/i/u/300x300/corrected-cover.png"
    respond(monkeypatch, {"recenttracks": {"track": [track(art=fresh_art)]}})
    assert source.get_current().art_url == fresh_art


def test_retry_worker_start_failure_can_recover(source, monkeypatch):
    def fail(thread):
        raise RuntimeError("no available thread")
    monkeypatch.setattr(threading.Thread, "start", fail)
    assert not source.retry()
    assert source.status()["state"] == "unavailable"
    assert source._flight is None
