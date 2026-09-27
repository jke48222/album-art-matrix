"""Credential-free data for the S04–S08 native service captures."""
import time
from connections_fixtures import configure as base


def configure(wall, phase="connected"):
    payload = base(wall, "connected")
    now = int(time.time())
    track = {"title": "Into the Quiet", "artist": "The Tessera Sessions", "album": "After the Rain"}
    payload.update({
        "lastfm": {"user": "tessera_studies", "key_set": True, "state": "playing", "checked_at": now,
                   "current": track, "last_listen": {**track, "at": now - 1200}, "problem": None, "can_retry": True},
        "listenbrainz": {"user": "tessera_studies", "token_set": True, "valid": True, "user_name": "tessera_studies",
                        "state": "ready", "read_state": "playing", "read_playing": track, "read_problem": None,
                        "read_checked_at": now, "playing": {**track, "heard_s": 83, "needs_s": 126, "listened": False, "counting": True},
                        "counting": True, "last_listen": {**track, "at": now - 1200, "kind": "listen"},
                        "queued": 0, "held_queued": 0, "queue_saved": True, "submitted": 37, "problem": None},
        "claude": {"ready": True, "key_set": True, "workspace_set": False, "model": "claude-opus-5",
                   "answers": 12, "cost_usd": 0.074, "problem": None,
                   "last": {"q": "What was playing after dinner?", "a": "Into the Quiet by The Tessera Sessions was the most recent track.", "ts": now - 1200}},
        "discogs": {"user": "tessera_studies", "token_set": True, "releases": 163, "synced_at": now - 1200,
                    "syncing": False, "problem": None, "pages_read": 0, "pages_total": 0, "releases_read": 0},
    })
    if phase == "unlinked":
        payload["lastfm"].update(user="", key_set=False, state="unconfigured", current=None, last_listen=None)
        payload["listenbrainz"].update(user="", token_set=False, valid=None, user_name=None, state="unlinked", read_state="unlinked", read_playing=None, playing=None, counting=False, last_listen=None, submitted=0)
        payload["claude"].update(ready=False, key_set=False, answers=0, last=None, cost_usd=0)
        payload["discogs"].update(user="", token_set=False, releases=0, synced_at=None)
    elif phase == "refused":
        payload["lastfm"].update(state="refused", current=None, problem="Last.fm refused this API key. Replace it and check again.")
        payload["listenbrainz"].update(valid=False, state="refused", playing=None, counting=False, problem="ListenBrainz refused the token. Replace it in your account settings.")
        payload["claude"].update(problem="Claude refused the key. Replace it in connection settings.")
        payload["discogs"].update(problem="Discogs refused the token. Replace it and sync again.")
    elif phase == "queued":
        payload["listenbrainz"].update(state="offline", queued=3, held_queued=2, problem="ListenBrainz is unavailable. Saved listens will retry.")
    elif phase == "paused":
        payload["listenbrainz"]["playing"]["counting"] = False
        payload["listenbrainz"]["counting"] = False
    elif phase == "syncing":
        payload["discogs"].update(syncing=True, pages_read=2, pages_total=4, releases_read=100)
    elif phase == "empty":
        payload["lastfm"].update(state="idle", current=None, last_listen=None)
        payload["listenbrainz"].update(read_state="ready", read_playing=None, playing=None, counting=False, last_listen=None, submitted=0)
        payload["claude"].update(answers=0, last=None, cost_usd=0)
        payload["discogs"].update(releases=0)
    wall.studies["/services"] = payload
    return payload
