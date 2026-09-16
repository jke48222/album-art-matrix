"""Offline listening sessions with a fixture clock and a recording transport."""
from dataclasses import asdict
import json

import pytest
import requests

from brain.features import Features
from brain.nowplaying import NowPlaying
from brain.scrobble import Scrobbler, threshold, listen, BACKOFF, MAX_AGE
from brain.services import Services


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0
    def __call__(self):
        return self.t
    def advance(self, seconds):
        self.t += seconds


class Store:
    token = "12345678-1234-1234-1234-123456789abc"
    def get(self, section, key):
        return self.token


class Transport:
    def __init__(self):
        self.calls = []
        self.code = 200
        self.headers = {}
    def __call__(self, url, **kwargs):
        self.calls.append(kwargs["json"])
        if self.code is None:
            raise requests.ConnectionError("fixture connection lost")
        return self
    @property
    def status_code(self):
        return self.code


@pytest.fixture
def rig(tmp_path):
    clock, transport, store = Clock(), Transport(), Store()
    feature = Features({"features": {"scrobble": True}})
    worker = Scrobbler(store, feature, root=tmp_path, clock=clock, monotonic=clock, post=transport)
    return worker, clock, transport


def song(length=200000, title="A Song", source="ears"):
    return NowPlaying(source + ":one", title, "An Artist", "An Album", None, None, length, True, "GB1234567890")


def hear(rig, seconds, track=None, audible=True, confirmed=1):
    worker, clock, transport = rig
    for _ in range(int(seconds * 4)):
        clock.advance(.25)
        worker.observe(track or song(), audible, confirmed)


@pytest.mark.parametrize("length, seconds", [(200000, 100), (600000, 240), (None, 240), (0, 240)])
def test_half_or_four_minutes(rig, length, seconds):
    worker, clock, transport = rig
    track = song(length)
    worker.observe(track, True, 1)
    worker.deliver()
    assert transport.calls[0]["listen_type"] == "playing_now"
    assert "listened_at" not in transport.calls[0]["payload"][0]
    hear(rig, seconds - .25, track)
    assert worker.status()["queued"] == 0
    hear(rig, .25, track)
    assert worker.status()["queued"] == 1
    worker.deliver()
    assert transport.calls[-1]["listen_type"] == "single"
    assert transport.calls[-1]["payload"][0]["listened_at"] == 1_800_000_000


def test_payload_shape():
    payload = listen(asdict(song()), 1_800_000_000)
    assert set(payload) == {"listened_at", "track_metadata"}
    meta = payload["track_metadata"]
    assert meta["track_name"] == "A Song" and meta["artist_name"] == "An Artist"
    info = meta["additional_info"]
    assert info == {"media_player": "Album Art Matrix", "submission_client": "album-art-matrix",
                    "submission_client_version": "1.1.0", "music_service_name": "vinyl",
                    "tags": ["wall"], "isrc": "GB1234567890", "duration_ms": 200000}


def test_silence_does_not_earn_time(rig):
    worker, clock, transport = rig
    worker.observe(song(), True, 1)
    hear(rig, 40)
    hear(rig, 80, audible=False)
    hear(rig, 40)
    assert worker.status()["queued"] == 0
    hear(rig, 21)
    assert worker.status()["queued"] == 1


def test_hold_and_reheard_before_end_are_one_listen(rig):
    worker, clock, transport = rig
    worker.observe(song(), True, 1)
    hear(rig, 101)
    worker.observe(None)
    clock.advance(10)
    worker.observe(song(), True, 2)
    hear(rig, 400, confirmed=2)
    assert worker.status()["queued"] == 1
    assert len(worker.sessions) == 1


def test_reheard_after_end_is_new_performance(rig):
    worker, clock, transport = rig
    worker.observe(song(), True, 1)
    hear(rig, 201)
    worker.observe(song(), True, 2)
    hear(rig, 101, confirmed=2)
    assert worker.status()["queued"] == 2
    assert len({r["at"] for r in worker.queue if r["kind"] == "single"}) == 2


def test_other_sources_and_disabled_do_not_report(rig):
    worker, clock, transport = rig
    worker.observe(song(source="phone"), True, 1, source="phone")
    assert not worker.queue
    worker.features = Features()
    worker.observe(song(), True, 1)
    worker.deliver()
    assert not transport.calls


@pytest.mark.parametrize("code", [None, 500, 503, 429])
def test_failed_listens_backoff_and_import(rig, code):
    worker, clock, transport = rig
    worker.observe(song(), True, 1)
    worker.deliver()
    hear(rig, 101)
    transport.code = code
    for delay in BACKOFF:
        worker.deliver()
        pending = worker.queue[0]
        assert pending["next"] == clock() + delay
        count = len(transport.calls)
        clock.advance(delay - .25)
        worker.deliver()
        assert len(transport.calls) == count
        clock.advance(.25)
    transport.code = 200
    worker.deliver()
    assert transport.calls[-1]["listen_type"] == "import"
    assert worker.status()["queued"] == 0


@pytest.mark.parametrize("code", [400, 401, 403, 404, 422])
def test_permanent_errors_drop_without_retry(rig, code):
    worker, clock, transport = rig
    worker.observe(song(), True, 1)
    worker.deliver()
    hear(rig, 101)
    transport.code = code
    worker.deliver()
    assert not worker.queue
    assert f"HTTP {code}" in worker.status()["problem"]


def test_announcements_never_import_as_unearned_listens(rig):
    worker, clock, transport = rig
    transport.code = 503
    worker.observe(song(), True, 1)
    worker.deliver()
    clock.advance(60)
    worker.deliver()
    assert all(c["listen_type"] == "playing_now" for c in transport.calls)
    worker.observe(None)
    worker.deliver()
    assert worker.queue == []


def test_queue_survives_restart_and_expires(rig):
    worker, clock, transport = rig
    worker.observe(song(), True, 1)
    worker.deliver()
    hear(rig, 101)
    transport.code = 503
    worker.deliver()
    restored = Scrobbler(worker.store, worker.features, root=worker.root, clock=clock, monotonic=clock, post=transport)
    assert restored.status()["queued"] == 1
    restored.observe(song(), True, 2)
    assert restored.status()["queued"] == 1
    clock.advance(MAX_AGE + 1)
    restored.deliver()
    assert restored.status()["queued"] == 0
    assert worker.store.token not in worker.queue_path.read_text()


def test_retry_import_never_exceeds_fifty(rig):
    worker, clock, transport = rig
    for i in range(121):
        data = asdict(song(title=f"Song {i}"))
        worker.queue.append({"id": str(i), "session": str(i), "kind": "single", "at": clock(),
                             "payload": listen(data, clock()), "attempt": 1, "next": clock()})
    worker.deliver()
    assert len(transport.calls[-1]["payload"]) == 50
    assert worker.status()["queued"] == 71


def test_token_validation_and_redaction(tmp_path, monkeypatch):
    from brain import services
    monkeypatch.setattr(services, "PATH", str(tmp_path / "services.json"))
    store = Services({"listenbrainz": {"token": Store.token}})
    assert store.get("listenbrainz", "token") == ""
    assert store.update({"listenbrainz": {"token": "bad"}})[1]
    assert not store.update({"listenbrainz": {"token": Store.token}})[1]
    assert Services({}).get("listenbrainz", "token") == Store.token
    assert (tmp_path / "services.json").stat().st_mode & 0o777 == 0o600


def test_features_reload_and_keep_last_good(tmp_path):
    path = tmp_path / "config.toml"
    path.write_text('[features]\nscrobble = true\n')
    feature = Features(path=path)
    feature.reload()
    assert feature.enabled("scrobble")
    path.write_text('broken = [')
    feature.reload()
    assert feature.enabled("scrobble") and feature.problem
    path.write_text('[features]\nscrobble = false\n')
    feature.reload()
    assert not feature.enabled("scrobble") and feature.problem is None
