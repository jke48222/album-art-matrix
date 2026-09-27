"""Real HTTP contracts for music-reader retries and merged connection status."""
import copy
import json
from types import SimpleNamespace

import pytest

from brain.tests.test_control import api  # noqa: F401


class Reader:
    def __init__(self, name, accepted=True):
        self.name = name
        self.user = "reader-profile"
        self.api_key = "private-reader-api-key"
        self.accepted = accepted
        self.calls = 0

    def retry(self):
        self.calls += 1
        return self.accepted

    def status(self):
        if self.name == "lastfm":
            return {"user": self.user, "key_set": True, "state": "playing", "can_retry": True,
                    "current": {"title": "Night Signals", "artist": "Tessera Ensemble"}}
        return {"user": self.user, "read_state": "playing", "read_problem": None,
                "read_checked_at": 1700000000,
                "read_playing": {"title": "Night Signals", "artist": "Tessera Ensemble", "album": "Prism"}}


class Writer:
    def __init__(self, accepted=True):
        self.token = "private-writer-token"
        self.accepted = accepted
        self.calls = 0

    def retry(self):
        self.calls += 1
        return self.accepted

    def status(self):
        return {"user": "writer-profile", "token_set": True, "valid": True, "user_name": "writer-profile",
                "sources": ["ears"], "playing": {"title": "Room Song", "artist": "Tessera Ensemble", "heard_s": 41, "needs_s": 90},
                "last_listen": {"title": "Earlier Song", "artist": "Tessera Ensemble"},
                "queued": 2, "held_queued": 1, "submitted": 12, "state": "ready", "counting": True,
                "problem": None, "checked_at": 1700000001}


def install(api, path, *, reader=True, writer=True, accepted=True):
    if path == "/lastfm/retry":
        source = Reader("lastfm", accepted)
        api.ctrl.lastfm = source if reader else None
        return source, None
    source, sink = Reader("listenbrainz", accepted), Writer(accepted)
    api.ctrl.listenbrainz = source if reader else None
    api.ctrl.scrobbler = sink if writer else None
    return source, sink


@pytest.mark.parametrize("path", ["/lastfm/retry", "/listenbrainz/retry"])
def test_missing_retry_endpoint_is_404_without_nudge(api, path):
    api.ctrl.repoll.clear(); api.ctrl.dirty.clear()
    code, body = api.post(path, {})
    assert code == 404 and body["error"]
    assert not api.ctrl.repoll.is_set() and not api.ctrl.dirty.is_set()


@pytest.mark.parametrize("path", ["/lastfm/retry", "/listenbrainz/retry"])
def test_all_reject_is_409_without_nudge(api, path):
    reader, writer = install(api, path, accepted=False)
    api.ctrl.repoll.clear(); api.ctrl.dirty.clear()
    code, body = api.post(path, {})
    assert code == 409 and body["error"]
    assert reader.calls == 1 and (writer is None or writer.calls == 1)
    assert not api.ctrl.repoll.is_set() and not api.ctrl.dirty.is_set()


@pytest.mark.parametrize("path", ["/lastfm/retry", "/listenbrainz/retry"])
@pytest.mark.parametrize("raw", [b"{", b"[]", b"null", b'"not an object"'])
def test_malformed_body_cannot_trigger_retry(api, path, raw):
    reader, writer = install(api, path)
    assert api.post(path, raw=raw)[0] == 400
    assert reader.calls == 0 and (writer is None or writer.calls == 0)


@pytest.mark.parametrize("path", ["/lastfm/retry", "/listenbrainz/retry"])
def test_accepted_retry_nudges_and_returns_only_public_status(api, path):
    reader, writer = install(api, path)
    api.ctrl.repoll.clear(); api.ctrl.dirty.clear()
    code, body = api.post(path, {})
    assert code == 200
    assert api.ctrl.repoll.is_set() and api.ctrl.dirty.is_set()
    assert reader.calls == 1 and (writer is None or writer.calls == 1)
    assert set(body) >= {"lastfm", "listenbrainz", "spotify"}
    serialized = json.dumps(body)
    assert reader.api_key not in serialized and "private-writer-token" not in serialized
    assert "api_key" not in body["lastfm"] and "token" not in body["listenbrainz"]


@pytest.mark.parametrize("reader_accepts,writer_accepts,expected", [(True, True, 200), (True, False, 200), (False, True, 200), (False, False, 409)])
def test_every_listenbrainz_component_is_called(api, reader_accepts, writer_accepts, expected):
    reader, writer = install(api, "/listenbrainz/retry")
    reader.accepted, writer.accepted = reader_accepts, writer_accepts
    assert api.post("/listenbrainz/retry", {})[0] == expected
    assert reader.calls == 1 and writer.calls == 1


@pytest.mark.parametrize("reader,writer", [(True, False), (False, True)])
def test_listenbrainz_retry_supports_one_component(api, reader, writer):
    source, sink = install(api, "/listenbrainz/retry", reader=reader, writer=writer)
    code, body = api.post("/listenbrainz/retry", {})
    assert code == 200
    assert source.calls == int(reader) and sink.calls == int(writer)
    assert body["listenbrainz"]["user"] == (source.user if reader else "writer-profile")
    assert body["listenbrainz"]["token_set"] is writer


def test_legacy_listenbrainz_reader_does_not_block_writer_retry(api):
    api.ctrl.listenbrainz = SimpleNamespace(user="legacy-reader")
    api.ctrl.scrobbler = Writer()
    assert api.post("/listenbrainz/retry", {})[0] == 200
    assert api.ctrl.scrobbler.calls == 1


def test_legacy_lastfm_without_retry_reports_unavailable(api):
    api.ctrl.lastfm = SimpleNamespace(user="legacy-reader", api_key="private-api-key")
    assert api.post("/lastfm/retry", {})[0] == 404
    code, body = api.get("/services")
    assert code == 200 and body["lastfm"] == {"user": "legacy-reader", "key_set": True}
    assert "private-api-key" not in json.dumps(body)


def test_services_keeps_listenbrainz_reader_and_writer_states_separate(api):
    reader, writer = install(api, "/listenbrainz/retry")
    reader_snapshot, writer_snapshot = copy.deepcopy(reader.status()), copy.deepcopy(writer.status())
    code, body = api.get("/services")
    assert code == 200
    result = body["listenbrainz"]
    for field in ("read_state", "read_problem", "read_playing", "read_checked_at"):
        assert result[field] == reader_snapshot[field]
    for field in ("token_set", "valid", "user_name", "sources", "playing", "last_listen", "queued", "submitted", "state", "counting", "problem", "checked_at"):
        assert result[field] == writer_snapshot[field]
    assert result["user"] == reader.user
    assert reader.status() == reader_snapshot and writer.status() == writer_snapshot
    assert result["read_playing"]["title"] != result["playing"]["title"]


@pytest.mark.parametrize("path", ["/lastfm/retry-extra", "/listenbrainz/retry-extra", "/listenbrainz/retry/", "/listenbrainz/retry?force=true"])
def test_retry_paths_are_exact(api, path):
    install(api, "/listenbrainz/retry")
    install(api, "/lastfm/retry")
    assert api.post(path, {})[0] == 404
    assert api.ctrl.lastfm.calls == 0 and api.ctrl.listenbrainz.calls == 0 and api.ctrl.scrobbler.calls == 0
