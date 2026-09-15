"""The scrobbler, driven with a fake ear, a fake clock and a fake network.

    .venv/bin/python -m pytest brain/tests/test_scrobble.py -q
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying import NowPlaying                     # noqa: E402
from brain.scrobble import (Scrobbler, listen_payload,     # noqa: E402
                            LISTEN_AFTER_S, RETRY_S, RETRY_HOURLY_S, QUEUE_MAX_AGE_S)


def song(title="Nights", artist="Frank Ocean", album="Blonde", key="k1", dur=None):
    return NowPlaying(track_id=f"ears:{key}", title=title, artist=artist, album=album,
                      art_url="https://x/a.jpg", progress_ms=None,
                      duration_ms=dur, is_playing=True)


class Room:
    """A fake ear and a fake ListenBrainz, with the clocks in our hands."""

    def __init__(self, tmp_path, token="12345678-1234-1234-1234-123456789abc"):
        self.t = 1_700_000_000.0
        self.m = 1000.0
        self.current = None
        self.gate = True
        self.answers = []          # (code, json, headers) queue; default 200
        self.posts = []            # (path, method, body)
        self.marks = []
        s = self
        class Ctrl:
            ears = None
            def journal_mark(self, title, artist, since_ts, patch):
                s.marks.append((title, artist, since_ts, patch))
                return 1
        self.scr = Scrobbler(Ctrl(), user="jalen", token=token,
                             queue_path=str(tmp_path / "scrobbles.jsonl"),
                             clock=lambda: self.t, mono=lambda: self.m,
                             post=self.post, gate=lambda: self.gate,
                             current=lambda: self.current)

    def post(self, path, body, method="POST"):
        self.posts.append((path, method, body))
        if self.answers:
            return self.answers.pop(0)
        if path == "/validate-token":
            return 200, {"valid": True, "user_name": "jalen"}, {}
        return 200, {"status": "ok"}, {}

    def tick(self, dt=2.0):
        self.t += dt
        self.m += dt
        self.scr.tick(dt)

    def run(self, seconds, dt=2.0):
        for _ in range(int(seconds / dt)):
            self.tick(dt)

    def sent(self, kind):
        return [b for p, m, b in self.posts if p == "/submit-listens" and b and b["listen_type"] == kind]


def test_payload_shape():
    meta = listen_payload(song(dur=180000), isrc="USQX91600001")
    assert meta["artist_name"] == "Frank Ocean" and meta["track_name"] == "Nights"
    assert meta["release_name"] == "Blonde"
    info = meta["additional_info"]
    assert info["isrc"] == "USQX91600001" and info["duration_ms"] == 180000
    assert info["music_service_name"] == "vinyl" and info["media_player"] == "Album Art Matrix"
    assert info["submission_client"] == "album-art-matrix" and "wall" in info["tags"]
    assert "release_name" not in listen_payload(song(album="?"))


def test_playing_now_then_listen_at_half(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=200_000)             # 200 s song: a listen after 100 s
    r.tick()
    assert len(r.sent("playing_now")) == 1
    assert r.sent("single") == []
    r.run(96)
    assert r.sent("single") == []
    r.run(6)
    singles = r.sent("single")
    assert len(singles) == 1
    p = singles[0]["payload"][0]
    assert p["listened_at"] == int(1_700_000_002)       # the first hearing
    assert p["track_metadata"]["track_name"] == "Nights"
    r.run(300)
    assert len(r.sent("single")) == 1                    # once per play
    assert r.marks and r.marks[0][3] == {"scrobbled": True}
    assert r.scr.status()["last_listen"]["title"] == "Nights"
    assert r.scr.status()["submitted"] == 1


def test_four_minutes_when_length_unknown(tmp_path):
    r = Room(tmp_path)
    r.current = song()
    r.run(LISTEN_AFTER_S - 4)
    assert r.sent("single") == []
    r.run(8)
    assert len(r.sent("single")) == 1


def test_only_loud_time_counts(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=200_000)
    r.gate = False
    r.run(300)
    assert r.sent("single") == []
    r.gate = True
    r.run(104)
    assert len(r.sent("single")) == 1


def test_heard_again_within_the_song_is_one_play(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=300_000)
    r.run(60)
    r.current = None                          # the ear let go (a conversation)
    r.run(30)
    r.current = song(dur=300_000)             # and named it again
    r.run(100)
    assert len(r.sent("single")) == 1
    assert len(r.sent("playing_now")) == 2    # the note expired, sent again


def test_heard_again_after_the_song_is_a_new_play(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=120_000)
    r.run(70)
    assert len(r.sent("single")) == 1
    r.current = None
    r.run(60)                                 # past the song's own length
    r.current = song(dur=120_000)
    r.run(70)
    assert len(r.sent("single")) == 2


def test_another_cut_of_the_same_song_is_the_same_play(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=200_000, key="k1")
    r.run(20)
    r.current = song(dur=200_000, key="k2", title="Nights [Extended]")   # a different cut
    r.run(20)
    assert len(r.sent("playing_now")) == 1    # the bracketed part is not a new song
    r.current = song(dur=200_000, key="k1")
    r.run(64)
    assert len(r.sent("single")) == 1         # 20 + 20 + 64 s heard of a 200 s song


def test_no_token_means_nothing_is_sent(tmp_path):
    r = Room(tmp_path, token="")
    r.current = song(dur=100_000)
    r.run(300)
    assert r.posts == []


def test_rejected_token_stops_posting(tmp_path):
    r = Room(tmp_path)
    r.answers.append((200, {"valid": False}, {}))       # validate-token
    r.current = song(dur=100_000)
    r.tick()
    assert r.scr.status()["valid"] is False
    n = len(r.posts)
    r.run(200)
    assert len(r.posts) == n                              # nothing more went out
    assert r.scr.status()["queued"] == 1                  # the listen waits for a new token


def test_network_down_queues_and_retries_with_backoff(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=100_000)
    r.tick()                                              # playing_now + validate
    r.answers.append((0, {"error": "down"}, {}))          # the listen fails
    r.run(60)
    assert r.scr.status()["queued"] == 1
    assert "no network" in r.scr.status()["problem"]
    q = json.loads(open(r.scr.queue_path).read().splitlines()[0])
    assert q["tries"] == 1 and q["next"] <= r.t + RETRY_S[0]
    r.answers.append((503, {}, {}))                       # first retry fails too
    r.run(RETRY_S[0] + 4)
    assert r.scr.status()["queued"] == 1
    assert json.loads(open(r.scr.queue_path).read().splitlines()[0])["tries"] == 2
    r.run(RETRY_S[1] + 4)                                 # second retry lands
    assert r.scr.status()["queued"] == 0
    imports = r.sent("import")                            # the 503 try, then the one that landed
    assert len(imports) == 2 and imports[-1]["payload"][0]["track_metadata"]["track_name"] == "Nights"
    assert not open(r.scr.queue_path).read().strip()


def test_backoff_goes_hourly_and_gives_up_after_a_week(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=100_000)
    r.tick()
    for _ in range(3):
        r.answers.append((0, {"error": "down"}, {}))
    r.run(60)
    r.run(RETRY_S[0] + 4)
    r.run(RETRY_S[1] + 4)
    q = json.loads(open(r.scr.queue_path).read().splitlines()[0])
    assert q["tries"] == 3
    r.answers.append((0, {"error": "down"}, {}))
    r.run(RETRY_S[2] + 4)
    q = json.loads(open(r.scr.queue_path).read().splitlines()[0])
    assert q["tries"] == 4 and q["next"] - r.t > RETRY_HOURLY_S - 60   # slack: each stage retries a tick late
    r.t += QUEUE_MAX_AGE_S + 10                            # a week goes by, still down
    r.m += QUEUE_MAX_AGE_S + 10
    r.answers.append((0, {"error": "down"}, {}))
    r.tick()
    assert r.scr.status()["queued"] == 0


def test_malformed_listen_is_dropped_not_retried(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=100_000)
    r.tick()
    r.answers.append((400, {"error": "bad"}, {}))
    r.run(60)
    assert r.scr.status()["queued"] == 0


def test_rate_limit_waits(tmp_path):
    r = Room(tmp_path)
    r.answers.append((200, {"valid": True, "user_name": "jalen"}, {}))
    r.current = song(dur=100_000)
    r.answers.append((429, {}, {"X-RateLimit-Reset-In": "40"}))     # playing_now
    r.tick()
    assert "rate limited" in r.scr.status()["problem"]
    before = len(r.posts)
    r.run(30)
    assert len(r.posts) == before                          # quiet while limited
    r.run(80)                                              # limit over: the listen (queued) goes as import
    assert r.scr.status()["queued"] == 0
    assert r.sent("import") or r.sent("single")


def test_queue_survives_a_restart(tmp_path):
    r = Room(tmp_path)
    r.current = song(dur=100_000)
    r.tick()
    r.answers.append((0, {"error": "down"}, {}))
    r.run(60)
    assert r.scr.status()["queued"] == 1
    again = Room(tmp_path)
    again.t, again.m = r.t, r.m               # the clock keeps running across a restart
    assert again.scr.status()["queued"] == 1
    again.run(RETRY_S[0] + 4)
    assert again.scr.status()["queued"] == 0


def test_two_records_interleaved_keep_their_own_plays(tmp_path):
    r = Room(tmp_path)
    a = song(title="A", key="a", dur=400_000)
    b = song(title="B", artist="Someone", key="b", dur=400_000)
    r.current = a
    r.run(100)
    r.current = b                             # a second record cut in
    r.run(60)
    r.current = a                             # and the first came back, within its length
    r.run(110)
    singles = r.sent("single")
    assert [p["payload"][0]["track_metadata"]["track_name"] for p in singles] == ["A"]
    assert len(r.sent("playing_now")) == 3
