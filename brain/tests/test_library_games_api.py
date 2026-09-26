"""Real loopback HTTP coverage for library, collection and game receipts."""
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
import threading
import socket

import numpy as np
import pytest

from brain.games import GAMES
from brain.games.host import GameHost
from brain.nowplaying.teach import Library, Teacher
from brain.shelf import Shelf
from brain.tests.test_control import api  # noqa: F401 — real server fixture
from brain.tests.test_games_batch import TestPuzzle


@pytest.fixture
def games(api, tmp_path, monkeypatch):
    monkeypatch.setitem(GAMES, TestPuzzle.name, TestPuzzle)
    api.ctrl.games = GameHost(api.ctrl, path=str(tmp_path / "games.json"))
    return api


def start(api):
    code, state = api.post("/game/start", {"name": TestPuzzle.name})
    assert code == 200
    return state["session_id"]


def test_game_catalogue_and_state_return_real_session(games):
    code, catalogue = games.get("/game/list")
    assert code == 200 and any(g["name"] == TestPuzzle.name for g in catalogue["games"])
    assert not catalogue["running"]
    sid = start(games)
    code, state = games.get("/game")
    assert code == 200 and state["session_id"] == sid and state["on_wall"]
    assert state["game"]["name"] == TestPuzzle.name


@pytest.mark.parametrize("path", ["/games", "/game/listing", "/game/start", "/game/unknown", "/game/list/extra"])
def test_game_get_routes_are_exact(games, path):
    assert games.get(path)[0] == 404


@pytest.mark.parametrize("path", ["/game/start-extra", "/game/endless", "/game/movement", "/game/hearing", "/game/resumed"])
def test_unknown_game_post_route_cannot_mutate_game(games, path):
    sid = start(games)
    code, body = games.post(path, {"name": TestPuzzle.name, "session_id": sid, "move": {"finish": True}})
    assert code == 404 and body["error"]
    assert games.ctrl.games.session_id == sid and not games.ctrl.games.game.over


@pytest.mark.parametrize("path,payload", [
    ("/game/move", {"move": {"finish": True}}), ("/game/hear", {"text": "finish"}),
    ("/game/end", {}), ("/game/resume", {}), ("/game/start", {"name": TestPuzzle.name})])
def test_http_stale_receipt_cannot_change_new_game(games, path, payload):
    old = start(games)
    fresh = start(games)
    seq = games.ctrl.games.seq
    code, body = games.post(path, {**payload, "session_id": old})
    assert code == 409 and body["session_id"] == fresh and body["error"]
    assert games.ctrl.games.seq == seq and not games.ctrl.games.game.over


@pytest.mark.parametrize("path,payload", [
    ("/game/start", {"name": 10}), ("/game/start", {"name": TestPuzzle.name, "options": []}),
    ("/game/start", {"name": TestPuzzle.name, "players": [True]}),
    ("/game/move", {"move": []}), ("/game/move", {"move": {}, "player": 2}),
    ("/game/end", {"session_id": False}), ("/game/hear", {"text": " "}),
    ("/game/hear", {"text": "a" * 1001}), ("/game/hear", {"text": ["word"]})])
def test_game_payload_validation_is_400_and_nonmutating(games, path, payload):
    sid = start(games)
    code, body = games.post(path, payload)
    assert code == 400 and body["error"]
    assert games.ctrl.games.session_id == sid and not games.ctrl.games.game.over


def test_game_setup_failure_has_502_and_preserves_old_session(games, monkeypatch):
    sid = start(games)
    class Failing(TestPuzzle):
        name = "api-failing"
        def setup(self): raise RuntimeError("provider down")
    monkeypatch.setitem(GAMES, Failing.name, Failing)
    code, body = games.post("/game/start", {"name": Failing.name, "session_id": sid})
    assert code == 502 and body["session_id"] == sid and body["starting"] is None
    assert games.ctrl.get()["mode"] == "game"


def test_real_http_status_and_end_remain_responsive_during_setup(games, monkeypatch):
    started, finish = threading.Event(), threading.Event()
    class Preparing(TestPuzzle):
        name = "api-preparing"
        def setup(self):
            super().setup(); started.set(); assert finish.wait(4)
    monkeypatch.setitem(GAMES, Preparing.name, Preparing)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(games.post, "/game/start", {"name": Preparing.name})
        try:
            assert started.wait(2)
            code, state = games.get("/game")
            assert code == 200 and state["starting"] == Preparing.name
            assert games.post("/game/start", {"name": TestPuzzle.name})[0] == 409
            assert games.post("/game/end", {})[0] == 200
        finally:
            finish.set()
        code, state = pending.result(timeout=3)
    assert code == 409 and not state["running"] and games.ctrl.get()["mode"] == "art"


def test_resume_is_explicit_and_ending_hidden_game_preserves_off(games):
    sid = start(games)
    games.post("/state", {"mode": "off"})
    assert games.get("/game")[1]["on_wall"] is False
    assert games.ctrl.get()["mode"] == "off"
    code, resumed = games.post("/game/resume", {"session_id": sid})
    assert code == 200 and resumed["on_wall"]
    code, ended = games.post("/game/end", {"session_id": sid})
    assert code == 200 and ended["ended"] and games.ctrl.get()["mode"] == "off"


def test_game_move_success_does_not_repeat_score_on_read_or_end(games):
    sid = start(games)
    assert games.post("/game/move", {"session_id": sid, "move": {"finish": True}})[0] == 200
    for _ in range(3): assert games.get("/game")[1]["scores"]["You"]["played"] == 1
    assert games.post("/game/end", {"session_id": sid})[0] == 200
    assert games.ctrl.games.scores(TestPuzzle.name)["You"]["played"] == 1


def test_unknown_game_and_unavailable_games_have_404(api):
    assert api.post("/game/start", {"name": "missing"})[0] == 404
    api.ctrl.games = GameHost(api.ctrl, path="/nonexistent/not-written.json")
    assert api.post("/game/start", {"name": "missing"})[0] == 404


@pytest.fixture
def shelf(api, tmp_path):
    calls = []
    def fetch(path, params):
        calls.append((path, params))
        return {"releases": [{"basic_information": {"id": 1, "title": "Blue", "artists": [{"name": "Joni Mitchell"}]}}]}
    api.ctrl.shelf = Shelf(api.ctrl, token="not-real", user="collector", path=str(tmp_path / "shelf.json"), fetch=fetch, clock=lambda: 1000)
    api.ctrl.shelf.sync()
    return api, calls


def test_shelf_http_ack_matches_completion_and_keeps_last_success_time(shelf):
    api, calls = shelf
    code, ack = api.post("/shelf/sync", {})
    assert code == 200 and ack["accepted"] and ack["syncing"] and ack["sync_id"]
    assert ack["synced_at"] == 1000
    assert api.post("/shelf/sync", {})[1]["sync_id"] == ack["sync_id"]
    api.ctrl.shelf.tick()
    code, result = api.get("/shelf")
    assert code == 200 and result["completed_sync_id"] == ack["sync_id"]
    assert not result["syncing"] and len(result["releases"]) == 1 and len(calls) == 2


@pytest.mark.parametrize("raw", [b"[]", b"false", b"broken", b'"string"'])
def test_shelf_bad_body_cannot_queue_read(shelf, raw):
    api, _ = shelf
    original = api.ctrl.shelf.sync_id
    assert api.post("/shelf/sync", raw=raw)[0] == 400
    assert api.ctrl.shelf.sync_id == original and not api.ctrl.shelf.status()["syncing"]


@pytest.mark.parametrize("path", ["/shelf/synced", "/shelf/sync/extra"])
def test_unknown_shelf_mutation_path_is_404_without_read(shelf, path):
    api, _ = shelf
    assert api.post(path, {})[0] == 404
    assert not api.ctrl.shelf.status()["syncing"]


def test_shelf_unavailable_and_unconfigured_statuscodes(api, tmp_path):
    assert api.post("/shelf/sync", {})[0] == 404
    api.ctrl.shelf = Shelf(api.ctrl, path=str(tmp_path / "shelf.json"))
    code, response = api.post("/shelf/sync", {})
    assert code == 400 and response["error"] and not response["syncing"]


@pytest.fixture
def teacher(api, tmp_path, monkeypatch):
    # Controlled audio landmarks keep HTTP/persistence behavior real without a
    # catalogue call, microphone, decoder executable or nondeterministic FFT.
    monkeypatch.setattr("brain.nowplaying.teach.fingerprint", lambda pcm: (np.arange(70, dtype=np.uint32), np.arange(70, dtype=np.int32)))
    lib = Library(path=str(tmp_path / "library"))
    ear = SimpleNamespace(_library_kept=lib, library=lib, teacher=None)
    fetch = lambda title, artist: (np.ones(16000 * 4, dtype=np.int16), {"title": title, "artist": artist})
    ear.teacher = Teacher(lib, ear, fetch=fetch)
    api.ctrl.ears = ear
    return api, lib, ear.teacher


def test_teach_learn_forget_and_clear_have_real_persisted_receipts(teacher):
    api, lib, _ = teacher
    code, learned = api.post("/teach/learn", {"title": "  Blue  ", "artist": " Joni Mitchell "})
    assert code == 200 and learned["learnt"]["title"] == "Blue" and learned["songs"] == 1
    sid = Library.song_id("Blue", "Joni Mitchell")
    code, listing = api.get("/teach")
    assert code == 200 and listing["enabled"] and listing["songs"][0]["id"] == sid
    assert Library(path=lib.path).has("Blue", "Joni Mitchell")
    code, forgotten = api.post("/teach/forget", {"id": sid})
    assert code == 200 and forgotten["forgot"] and forgotten["songs"] == 0
    assert api.post("/teach/forget", {"id": sid})[0] == 404
    assert api.post("/teach/learn", {"title": "Hejira", "artist": "Joni Mitchell"})[0] == 200
    assert api.post("/teach/clear", {})[1]["songs"] == 0
    assert Library(path=lib.path).listing() == []


def test_teach_busy_is_409_not_provider_error(teacher):
    api, _, instructor = teacher
    assert instructor._begin("Existing song", "Existing artist")
    try:
        code, response = api.post("/teach/learn", {"title": "Blue", "artist": "Joni Mitchell"})
        assert code == 409 and "learning another" in response["error"]
        assert api.get("/teach")[1]["teacher"]["learning"] == "Existing artist — Existing song"
    finally:
        instructor._finish()


@pytest.mark.parametrize("fields", [{"title": "", "artist": "A"}, {"title": 5, "artist": "A"}, {"title": "T", "artist": "a" * 201}, {"title": "T", "artist": False}])
def test_teach_invalid_names_are_400_without_learning(teacher, fields):
    api, lib, instructor = teacher
    assert api.post("/teach/learn", fields)[0] == 400
    assert lib.listing() == [] and instructor.status()["learning"] is None


def test_teach_missing_preview_is_404_and_retry_is_possible(teacher):
    api, lib, instructor = teacher
    instructor._fetch = lambda *a: None
    code, body = api.post("/teach/learn", {"title": "Blue", "artist": "Joni Mitchell"})
    assert code == 404 and "No preview" in body["error"]
    assert lib.listing() == [] and instructor.status()["learning"] is None
    assert instructor._begin("Again", "Artist")
    instructor._finish()


@pytest.mark.parametrize("operation", ["learn", "forget", "clear"])
def test_teach_disk_failure_is_502_and_retains_library(teacher, monkeypatch, operation):
    api, lib, instructor = teacher
    assert api.post("/teach/learn", {"title": "Blue", "artist": "Joni Mitchell"})[0] == 200
    before = lib.listing()
    original_replace = __import__("os").replace
    def fail_replace(source, target):
        if str(target).endswith("library.npz"): raise OSError("disk full")
        return original_replace(source, target)
    monkeypatch.setattr("brain.nowplaying.teach.os.replace", fail_replace)
    body = {"title": "Hejira", "artist": "Joni Mitchell"} if operation == "learn" else {"id": Library.song_id("Blue", "Joni Mitchell")}
    code, result = api.post("/teach/" + operation, body)
    assert code == 502 and "could not save" in result["error"]
    assert lib.listing() == before
    assert Library(path=lib.path).listing() == before
    assert instructor.status()["learning"] is None


def test_teaching_unavailable_and_unknown_routes_do_not_mutate(teacher):
    api, lib, _ = teacher
    api.ctrl.ears.teacher = None
    assert api.post("/teach/learn", {"title": "Blue", "artist": "Joni Mitchell"})[0] == 503
    assert api.post("/teach/clear-all", {})[0] == 404
    assert lib.listing() == []


def test_negative_content_length_is_rejected_before_client_closes_connection(games):
    # Keep the sending half open: rfile.read(-1) would block until EOF and
    # prevent this connection from receiving any response.
    with socket.create_connection(("127.0.0.1", games.port), timeout=2) as client:
        client.settimeout(2)
        client.sendall(b"POST /game/start HTTP/1.1\r\nHost: localhost\r\n"
                       b"Content-Type: application/json\r\nContent-Length: -1\r\n\r\n")
        response = client.recv(4096)
        assert response.startswith(b"HTTP/1.1 400 ") or response.startswith(b"HTTP/1.0 400 ")
    assert games.ctrl.games.game is None
    assert games.ctrl.get()["mode"] == "art"
