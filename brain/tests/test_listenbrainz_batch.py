"""Account isolation, durable scrobbles and public reading regressions."""
import json
import threading
from dataclasses import replace

import pytest
import requests

from brain.nowplaying.listenbrainz import ListenBrainzSource
from brain.tests.test_scrobble import Room, song


def queued_room(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=100_000)
    room.tick()
    room.answers.append((0, {}, {}))
    room.run(60)
    assert room.scr.status()["queued"] == 1
    return room


def test_paused_track_does_not_count_even_if_microphone_gate_stays_open(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=200_000)
    room.run(20)
    heard = room.scr.status()["playing"]["heard_s"]
    room.current = replace(room.current, is_playing=False)
    room.run(300)
    assert room.scr.status()["playing"]["heard_s"] == heard
    assert room.scr.status()["counting"] is False
    assert room.sent("single") == []
    room.current = replace(room.current, is_playing=True)
    room.run(90)
    assert len(room.sent("single")) == 1


@pytest.mark.parametrize("gap", [90, -10, float("inf"), float("nan")])
def test_unobserved_clock_gap_cannot_become_listening_time(tmp_path, gap):
    room = Room(tmp_path)
    room.current = song(dur=100_000)
    room.tick()
    heard = room.scr.episode.heard_s
    room.scr.tick(gap)
    assert room.scr.episode.heard_s == heard
    assert room.sent("single") == []


def test_new_track_does_not_inherit_the_preceding_poll_interval(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=100_000)
    room.tick()
    assert room.scr.episode.heard_s == 0
    room.tick()
    assert room.scr.episode.heard_s == 2
    room.current = song(title="Another record", key="another")
    room.tick()
    assert room.scr.episode.heard_s == 0


def test_disabled_source_does_not_record_an_ear(tmp_path):
    room = Room(tmp_path)
    room.scr.sources = ()
    room.current = song(dur=100_000)
    room.run(200)
    assert room.scr.episode is None
    assert room.sent("single") == []


def test_public_username_change_does_not_change_writer_account(tmp_path):
    room = queued_room(tmp_path)
    room.scr.configure(user="another-reader")
    room.run(100)
    assert len(room.sent("import")) == 1
    assert room.scr.user_name == "jalen"
    assert room.scr.status()["user"] == "another-reader"


def test_replacement_token_cannot_send_the_previous_accounts_queue(tmp_path):
    room = queued_room(tmp_path)
    room.current = None
    room.scr.configure(token="another-token")
    room.answers.append((200, {"valid": True, "user_name": "someone-else"}, {}))
    room.run(100)
    assert room.sent("import") == []
    assert room.scr.status()["queued"] == 0
    assert room.scr.status()["held_queued"] == 1
    assert room.scr.status()["last_listen"] is None
    room.scr.configure(token="third-token")
    room.answers.append((200, {"valid": True, "user_name": "jalen"}, {}))
    room.tick()
    assert len(room.sent("import")) == 1
    assert room.scr.status()["held_queued"] == 0


def test_removing_token_stops_writing_but_keeps_account_scoped_queue(tmp_path):
    room = queued_room(tmp_path)
    room.scr.configure(token="")
    room.run(100)
    assert room.scr.status()["token_set"] is False
    assert room.scr.status()["state"] == "unlinked"
    assert room.scr.status()["held_queued"] == 1
    assert room.sent("import") == []


def test_token_change_starts_counting_a_new_episode(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=100_000)
    room.run(40)
    room.scr.configure(token="new-token")
    room.tick()
    assert room.scr.episode.heard_s == 0
    room.run(30)
    assert room.sent("single") == []


def test_stale_token_validation_cannot_reconnect_after_unlink(tmp_path):
    room = Room(tmp_path)
    def post(path, body, method="POST"):
        room.scr.configure(token="")
        return 200, {"valid": True, "user_name": "old-user"}, {}
    room.scr._post = post
    room.tick()
    status = room.scr.status()
    assert status["valid"] is None
    assert status["user_name"] is None
    assert status["state"] == "unlinked"


def test_account_switch_during_send_does_not_apply_old_receipt(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=100_000)
    room.tick()
    def post(path, body, method="POST"):
        room.scr.configure(token="other-token")
        return 200, {"status": "ok"}, {}
    room.scr._post = post
    room.run(52)
    assert room.scr.status()["last_listen"] is None
    assert room.scr.status()["submitted"] == 0
    assert room.scr.status()["held_queued"] == 1


def test_retry_batch_is_still_durable_while_http_request_is_pending(tmp_path):
    room = queued_room(tmp_path)
    room.current = None
    def post(path, body, method="POST"):
        if path != "/submit-listens":
            return 200, {"status": "ok"}, {}
        disk = [json.loads(line) for line in open(room.scr.queue_path) if line.strip()]
        assert len(disk) == 1
        assert disk[0]["payload"] == body["payload"][0]
        return 200, {"status": "ok"}, {}
    room.scr._post = post
    room.run(100)
    assert room.scr.status()["queued"] == 0
    assert open(room.scr.queue_path).read() == ""


def test_401_preserves_counted_listen_in_queue(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=100_000)
    room.tick()
    room.answers.append((401, {"secret": "never expose this"}, {}))
    room.run(60)
    assert room.scr.status()["state"] == "refused"
    assert room.scr.status()["queued"] == 1
    assert "never expose" not in json.dumps(room.scr.status())


def test_unknown_validation_never_posts_with_unverified_token(tmp_path):
    room = Room(tmp_path)
    room.answers.append((0, {}, {}))
    room.current = song(dur=100_000)
    room.run(52)
    assert room.sent("single") == []
    assert room.sent("playing_now") == []
    assert room.scr.status()["queued"] == 1
    assert len(room.posts) == 1  # validation has a backoff, not a two-second storm


def test_unidentified_valid_token_is_not_allowed_to_write(tmp_path):
    room = Room(tmp_path)
    room.answers.append((200, {"valid": True}, {}))
    room.tick()
    assert room.scr.status()["valid"] is None
    assert room.scr.status()["state"] == "unavailable"


def test_corrupt_queue_line_does_not_discard_other_waiting_listens(tmp_path):
    room = queued_room(tmp_path)
    with open(room.scr.queue_path, "a") as stream:
        stream.write("broken\n[]\n{}\n")
    again = Room(tmp_path)
    assert again.scr.status()["queued"] == 1
    assert oct(__import__("os").stat(room.scr.queue_path).st_mode & 0o777) == "0o600"


def legacy_queue(tmp_path):
    room = queued_room(tmp_path)
    item = json.loads(open(room.scr.queue_path).read())
    item.pop("owner"); item.pop("owner_name")
    with open(room.scr.queue_path, "w") as stream:
        stream.write(json.dumps(item) + "\n")


def test_legacy_queue_goes_to_the_token_it_was_queued_under(tmp_path):
    legacy_queue(tmp_path)
    again = Room(tmp_path)          # the token services.json held at the upgrade
    assert again.scr.status()["queued"] == 1
    assert again.scr.status()["legacy_queued"] == 0
    again.run(200)                  # past the queued retry time
    assert len(again.sent("import")) == 1
    assert again.scr.status()["queued"] == 0


def test_legacy_queue_is_never_sent_to_a_later_account(tmp_path):
    legacy_queue(tmp_path)
    again = Room(tmp_path)
    again.scr.configure(token="somebody-else")
    again.answers.append((200, {"valid": True, "user_name": "new-user"}, {}))
    again.run(200)                  # past the queued retry time
    assert again.sent("import") == []
    assert again.scr.status()["held_queued"] == 1


def test_legacy_queue_without_any_token_stays_held(tmp_path):
    legacy_queue(tmp_path)
    again = Room(tmp_path, token="")
    assert again.scr.status()["legacy_queued"] == 1
    again.scr.configure(token="somebody-else")
    again.answers.append((200, {"valid": True, "user_name": "new-user"}, {}))
    again.run(200)                  # past the queued retry time
    assert again.sent("import") == []
    assert again.scr.status()["held_queued"] == 1


def test_queue_storage_failure_is_visible(tmp_path, monkeypatch):
    room = Room(tmp_path)
    def fail(*args, **kwargs):
        raise OSError("disk full")
    monkeypatch.setattr("brain.scrobble.os.replace", fail)
    room.current = song(dur=100_000)
    room.tick()
    room.answers.append((0, {}, {}))
    room.run(60)
    assert room.scr.status()["queue_saved"] is False
    assert room.scr.status()["queued"] == 1


class Response:
    def __init__(self, body=None, code=200, headers=None):
        self.body = body if body is not None else {"payload": {"listens": []}}
        self.status_code = code
        self.headers = headers or {}
    def json(self):
        return self.body
    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError("error")


def listen(title="A piece of music", **info):
    return {"payload": {"listens": [{"track_metadata": {"track_name": title, "artist_name": "Prism Studies", "additional_info": info}}]}}


def test_reader_empty_user_is_unlinked_and_makes_no_network_call(monkeypatch):
    source = ListenBrainzSource()
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: pytest.fail("unexpected network"))
    assert source.get_current() is None
    assert source.status()["read_state"] == "unlinked"


def test_reader_quotes_username_as_one_path_component(monkeypatch):
    source = ListenBrainzSource("a/b")
    def get(url, **kwargs):
        assert url.endswith("/a%2Fb/playing-now")
        assert "Authorization" not in kwargs["headers"]
        return Response()
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", get)
    assert source.get_current() is None
    assert source.status()["read_state"] == "ready"


def test_reader_clears_stale_song_when_service_is_offline(monkeypatch):
    source = ListenBrainzSource("listener")
    monkeypatch.setattr(source, "_art", lambda *args: None)
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: Response(listen()))
    assert source.get_current().title == "A piece of music"
    source._asked_at = 0
    def fail(*args, **kwargs):
        raise requests.ConnectionError("offline")
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", fail)
    assert source.get_current() is None
    assert source.status()["read_state"] == "offline"
    assert source.status()["read_playing"] is None


def join_checks():
    for thread in threading.enumerate():
        if thread.name == "listenbrainz-check":
            thread.join(3)


def test_reader_user_switch_ignores_in_flight_old_song(monkeypatch):
    source = ListenBrainzSource("first")
    monkeypatch.setattr(source, "_art", lambda *args: None)
    asked = []
    def get(url, **kwargs):
        asked.append(url)
        if len(asked) == 1:
            source.configure("second")
            return Response(listen())
        return Response()           # the new user: nothing playing
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", get)
    assert source.get_current() is None
    status = source.status()        # starts the new username's first check
    assert status["user"] == "second" and status["read_playing"] is None
    join_checks()
    assert asked[1].endswith("/second/playing-now")
    assert source.status()["read_state"] == "ready"
    assert source.status()["read_playing"] is None


@pytest.mark.parametrize("body", [None, [], {"payload": []}, {"payload": {"listens": [3]}}, {"payload": {"listens": [{"track_metadata": {"track_name": 3}}]}}])
def test_reader_malformed_response_is_recoverable(monkeypatch, body):
    source = ListenBrainzSource("listener")
    response = Response(); response.body = body
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: response)
    assert source.get_current() is None
    assert source.status()["read_state"] == "unavailable"


@pytest.mark.parametrize("rate", ["bad", "nan", "inf", "-1"])
def test_reader_rate_limit_header_cannot_break_polling(monkeypatch, rate):
    source = ListenBrainzSource("listener")
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: Response(code=429, headers={"X-RateLimit-Reset-In": rate}))
    assert source.get_current() is None
    assert source.status()["read_state"] == "rate_limited"
    assert source.retry() is False


def test_reader_retry_coalesces_and_checks_even_off_source_chain(monkeypatch):
    source = ListenBrainzSource("listener")
    started, finish = threading.Event(), threading.Event()
    def get(*args, **kwargs):
        started.set()
        assert finish.wait(3)
        return Response()
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", get)
    assert source.retry() is True
    assert started.wait(3)
    assert source.retry() is False
    finish.set()
    for thread in threading.enumerate():
        if thread.name == "listenbrainz-check":
            thread.join(3)
    assert source.status()["read_state"] == "ready"


def test_held_queue_expires_even_after_disconnect(tmp_path):
    room = queued_room(tmp_path)
    room.scr.configure(token="")
    room.t += 8 * 86400
    room.tick()
    assert room.scr.status()["held_queued"] == 0


def test_writer_retry_coalesces_and_checks_without_counting_time(tmp_path):
    room = Room(tmp_path)
    started, finish = threading.Event(), threading.Event()
    def post(path, body, method="POST"):
        started.set()
        assert finish.wait(3)
        return 200, {"valid": True, "user_name": "jalen"}, {}
    room.scr._post = post
    assert room.scr.retry() is True
    assert started.wait(3)
    assert room.scr.retry() is False
    finish.set()
    for thread in threading.enumerate():
        if thread.name == "listenbrainz-write-check":
            thread.join(3)
    assert room.scr.status()["state"] == "ready"
    assert room.scr.status()["playing"] is None


def test_pause_clears_only_the_walls_playing_notice_and_resume_announces_again(tmp_path):
    room = Room(tmp_path)
    room.current = song(dur=200_000)
    room.tick()
    room.gate = False
    room.tick()
    cleared = [body for path, method, body in room.posts if path == "/playing-now/delete"]
    assert cleared == [{"client": "album-art-matrix"}]
    room.run(10)
    assert len([path for path, method, body in room.posts if path == "/playing-now/delete"]) == 1
    room.gate = True
    room.tick()
    assert len(room.sent("playing_now")) == 2


def test_reader_status_expires_unpolled_playing_report_without_faking_idle(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr("brain.nowplaying.listenbrainz.time.monotonic", lambda: clock[0])
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: Response(listen()))
    source = ListenBrainzSource("listener")
    monkeypatch.setattr(source, "_art", lambda *args: None)
    assert source.get_current() is not None
    checked_at = source.status()["read_checked_at"]
    clock[0] += 29.9
    assert source.status()["read_state"] == "playing"
    assert source.status()["read_playing"] is not None
    clock[0] += 0.1
    # The report proved the username; only the song is unknown now.
    assert source.status()["read_state"] == "ready"
    assert source.status()["read_playing"] is None
    assert source.status()["read_checked_at"] == checked_at


def test_reader_busy_request_cannot_return_expired_cached_track(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr("brain.nowplaying.listenbrainz.time.monotonic", lambda: clock[0])
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: Response(listen()))
    source = ListenBrainzSource("listener")
    monkeypatch.setattr(source, "_art", lambda *args: None)
    assert source.get_current() is not None
    source._request_lock.acquire()
    try:
        clock[0] += 10
        assert source.get_current() is not None
        clock[0] += 21
        assert source.get_current() is None
        assert source.status()["read_playing"] is None
        assert source.status()["read_state"] == "ready"
    finally:
        source._request_lock.release()


def test_reader_true_idle_stays_ready_after_freshness_interval(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr("brain.nowplaying.listenbrainz.time.monotonic", lambda: clock[0])
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: Response())
    source = ListenBrainzSource("listener")
    assert source.get_current() is None
    clock[0] += 300
    assert source.status()["read_state"] == "ready"
    assert source.status()["read_playing"] is None
