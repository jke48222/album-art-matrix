"""Review follow-ups for the discovery, Claude, imagine, teach, reader and
reporter services. Real objects, fake providers, no network or hardware."""
import base64
import io
import json
import threading
import time
from types import SimpleNamespace

import numpy as np
import pytest
import requests
from PIL import Image

from brain import show
from brain.art import fetch as art_fetch
from brain.ask import Asker
from brain.control import ControlState
from brain.homekit import K_INFO
from brain.imagine import Imaginer
from brain.nowplaying.listenbrainz import MISSING_USER_S, ListenBrainzSource
from brain.nowplaying.teach import RATE, Library, Teacher, TeachTooShort
from brain.posters import Posters
from brain.tests.test_homekit_batch import bridge
from brain.tests.test_imagine import Ctrl as ImagineCtrl
from brain.tests.test_listenbrainz_batch import Response, listen
from brain.tests.test_shelf_batch import create as create_shelf
from brain.tests.test_voice import FakeAsker, FakeCtrl, FakeTranscriber, FakeWake, settle
from brain.voice.voice import Voice


# ---- show me: ownership is the picture, not the song counter --------------------------------

@pytest.fixture
def finder(monkeypatch):
    value = show.Shower(ControlState(frame_len=64 * 64 * 3))
    image = Image.new("RGB", (128, 96), (33, 91, 137))
    monkeypatch.setattr(show, "find_art", lambda query: {
        "title": "Signal", "artist": "North", "album": "Signal",
        "art_url": "https://example.test/sleeve.png", "score": 1.0})
    monkeypatch.setattr(show, "fetch_art", lambda url: image)
    yield value
    if value._timer is not None:
        value._timer.cancel()


def song_changes(ctrl):
    """What main.py does on every new track outside video."""
    ctrl.now_showing = {"title": "Next", "artist": "Someone", "album": "Else"}
    ctrl.shown_seq += 1


def test_a_song_change_does_not_orphan_a_picture(finder):
    finder.ctrl.apply({"mode": "art"})
    result = finder.show("Signal", "cover")
    song_changes(finder.ctrl)
    assert finder.discovery_status()["last"]["active"] is True
    finder._until = 0
    finder._take_down(finder._frame_seq)
    assert finder.ctrl.get()["mode"] == "art"
    assert finder.discovery_status()["last"]["id"] == result["id"]
    assert finder.discovery_status()["last"]["active"] is False


def test_second_picture_after_a_song_change_keeps_the_first_return_face(finder):
    finder.ctrl.apply({"mode": "clock"})
    finder.show("Signal", "cover")
    song_changes(finder.ctrl)
    finder.show("North", "cover")
    finder._until = 0
    finder._take_down(finder._frame_seq)
    assert finder.ctrl.get()["mode"] == "clock"


def test_a_song_change_during_a_search_is_not_a_new_selection(finder, monkeypatch):
    image = Image.new("RGB", (64, 64), (200, 30, 30))
    def slow_fetch(url):
        song_changes(finder.ctrl)
        return image
    monkeypatch.setattr(show, "fetch_art", slow_fetch)
    result = finder.show("Signal", "cover")
    assert "code" not in result and result["active"] is True
    assert finder.ctrl.get()["mode"] == "frame"


@pytest.mark.parametrize("choice", ["frame", "replay"])
def test_a_choice_during_a_search_still_wins(finder, monkeypatch, choice):
    finder.ctrl.apply({"mode": "art"})
    image = Image.new("RGB", (64, 64), (200, 30, 30))
    doodle = bytes([9] * (64 * 64 * 3))
    def slow_fetch(url):
        if choice == "frame":            # POST /frame from the phone
            finder.ctrl.frame_override = doodle
            finder.ctrl.apply({"mode": "frame"})
        else:                            # POST /replay while the wall is on art
            finder.ctrl.apply({"mode": "art"})
            finder.ctrl.replay = {"art_url": "x"}
            finder.ctrl.replay_active = True
        return image
    monkeypatch.setattr(show, "fetch_art", slow_fetch)
    assert finder.show("Signal", "cover")["code"] == 409
    assert finder.last_show is None
    if choice == "frame":
        assert finder.ctrl.frame_override is doodle


class FakeVideo:
    def __init__(self):
        self.url, self.busy = "", False

    def start(self, url, **kwargs):
        self.url, self.busy = url, True

    def stop(self, error=None):
        self.busy = False


def test_play_receipt_stays_active_once_the_player_names_the_video(finder, monkeypatch):
    finder.ctrl.video = FakeVideo()
    monkeypatch.setattr(show.ytdlp, "binary", lambda: "/usr/bin/yt-dlp")
    monkeypatch.setattr(show.subprocess, "run", lambda *a, **k: SimpleNamespace(
        returncode=0, stdout="abcdefghijk\nA video\n"))
    played = finder.play("a video")
    assert played["active"] is True
    finder.ctrl.video_media(SimpleNamespace(title="A video", author="Channel"))
    song_changes(finder.ctrl)
    assert finder.discovery_status()["last"]["active"] is True
    finder.ctrl.apply({"mode": "clock"})
    assert finder.discovery_status()["last"]["active"] is False


def test_earworm_error_is_the_guess_not_the_connection(finder):
    asker = SimpleNamespace(ready=True, problem="Claude rejected the key. Replace it in Services.",
                            earworm_problem="No confident match yet. Add another line, an artist, or the decade.",
                            earworm=lambda words: None)
    finder.asker = asker
    assert finder.earworm("hmm")["error"].startswith("No confident match")


# ---- Claude: success is explicit, and misses are not connection problems -------------------

def asker_with(parse=None, create=None):
    value = Asker(SimpleNamespace(), api_key="test-key")
    value._client = SimpleNamespace(messages=SimpleNamespace(parse=parse, create=create))
    return value


class Status(Exception):
    def __init__(self, code, text="failed"):
        super().__init__(text)
        self.status_code = code


def test_a_passing_game_failure_does_not_mark_claude(capsys):
    def parse(**kwargs):
        raise Status(500)
    value = asker_with(parse=parse)
    assert value.connections_set() is None and value.quiz_round(None) is None
    assert value.crossword_clues(["one"]) is None and value.strands_set() is None
    assert value.problem is None
    assert "[ask] connections" in capsys.readouterr().out


def test_a_refused_key_in_a_game_marks_claude_and_an_answer_clears_it():
    def refuse(**kwargs):
        raise Status(401)
    value = asker_with(parse=refuse)
    assert value.connections_set() is None
    assert value.problem == "Claude rejected the key. Replace it in Services."
    def answer(**kwargs):
        model = kwargs["output_format"]
        groups = [{"theme": f"t{i}", "words": [f"w{i}{j}" for j in range(4)]} for i in range(4)]
        return SimpleNamespace(parsed_output=model(groups=groups), usage=None)
    value._client.messages.parse = answer
    assert value.connections_set()
    assert value.problem is None


def test_image_prompt_timeout_is_not_a_connection_problem():
    def slow(**kwargs):
        raise TimeoutError("slow")
    value = asker_with(create=slow)
    assert value.image_prompt("a cat") is None
    assert value.problem is None


def test_answer_is_a_success_even_if_another_call_writes_a_problem(monkeypatch):
    value = Asker(SimpleNamespace(), api_key="test-key")
    def answered(question, size=64):
        value.problem = "Song identification could not finish."   # another thread, meanwhile
        return "Four records so far.", True
    monkeypatch.setattr(value, "_ask_answer", answered)
    assert value.ask_reply("What played?") == {"answer": "Four records so far.", "error": None, "busy": False}


def test_earworm_miss_leaves_the_connection_alone():
    def parse(**kwargs):
        model = kwargs["output_format"]
        return SimpleNamespace(parsed_output=model(title="", artist="", confidence=0, alternatives=[]))
    value = asker_with(parse=parse)
    value.problem = "Claude is limiting requests. Try again in a moment."
    assert value.earworm("la la") is None
    assert value.earworm_problem.startswith("No confident match")
    assert value.problem is None          # Claude answered, so the old problem is gone


def test_earworm_refused_key_is_both_the_guess_and_the_connection():
    def refuse(**kwargs):
        raise Status(401)
    value = asker_with(parse=refuse)
    assert value.earworm("la la") is None
    assert value.earworm_problem == value.problem == "Claude rejected the key. Replace it in Services."


# ---- imagine: plain failures, games leave the studio alone, the key stays verified ----------

def png(color=(20, 200, 90)):
    buffer = io.BytesIO()
    Image.new("RGB", (32, 32), color).save(buffer, "PNG")
    return buffer.getvalue()


def drawing_post(*_):
    return {"data": [{"b64_json": base64.b64encode(png()).decode()}]}


@pytest.mark.parametrize("failure,words", [
    (RuntimeError("401: The image provider couldn't accept this key or its permissions."), "couldn't accept this key"),
    (RuntimeError("429: The image provider's usage limit was reached. Check billing or try later."), "usage limit"),
    (RuntimeError("503: The image provider is temporarily unavailable."), "temporarily unavailable"),
    (RuntimeError("stream: Your request was rejected"), "stopped before the picture was finished"),
    (requests.ConnectionError("https://api.openai.com/v1/images?key=secret"), "couldn't reach the image provider"),
    (RuntimeError("no image in the answer (the prompt may have been refused)"), "sent no picture"),
])
def test_imagine_failures_are_plain_sentences(tmp_path, failure, words):
    def post(*_):
        raise failure
    studio = Imaginer(ImagineCtrl(), api_key="k" * 24, path=str(tmp_path / "im"), post=post)
    result = studio.imagine("a tree")
    assert words in result["error"] and result["error"] == studio.status()["problem"]
    assert ":" not in result["error"] and "Error" not in result["error"] and "secret" not in result["error"]


def test_a_game_drawing_never_touches_the_studio_problem(tmp_path):
    def post(*_):
        raise RuntimeError("503: The image provider is temporarily unavailable.")
    studio = Imaginer(ImagineCtrl(), api_key="k" * 24, path=str(tmp_path / "im"), post=post, clock=lambda: 9e9)
    studio.problem = "The studio's own failure."
    with pytest.raises(RuntimeError, match="temporarily unavailable"):
        studio.draw("a cat", expanded="a cat")
    assert studio.status()["problem"] == "The studio's own failure."
    studio._post = drawing_post
    studio._last_at = float("-inf")
    assert studio.draw("a cat", expanded="a cat").size == (32, 32)
    assert studio.status()["problem"] == "The studio's own failure."


def test_a_key_that_drew_stays_verified_across_a_restart(tmp_path):
    path = str(tmp_path / "im")
    studio = Imaginer(ImagineCtrl(), api_key="sk-first-key-123456", path=path, post=drawing_post)
    assert studio.imagine("a tree")["imagined"] and studio.status()["verified"]
    saved = open(tmp_path / "im" / "index.json").read()
    assert "sk-first-key-123456" not in saved
    assert Imaginer(ImagineCtrl(), api_key="sk-first-key-123456", path=path).status()["verified"]
    assert not Imaginer(ImagineCtrl(), api_key="sk-other-key-654321", path=path).status()["verified"]
    other = Imaginer(ImagineCtrl(), provider="google", api_key="sk-first-key-123456", path=path)
    assert not other.status()["verified"]
    again = Imaginer(ImagineCtrl(), api_key="sk-first-key-123456", path=path)
    again.configure(api_key="sk-other-key-654321")
    assert not again.status()["verified"]
    again.configure(api_key="sk-first-key-123456")
    assert again.status()["verified"]


# ---- fetching pictures from the web: bounded bytes and pixels -------------------------------

class Download:
    def __init__(self, body, length=None):
        self.body, self.headers = body, ({"Content-Length": str(length)} if length is not None else {})

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def raise_for_status(self):
        pass

    def iter_content(self, chunk_size):
        for i in range(0, len(self.body), chunk_size):
            yield self.body[i:i + chunk_size]


@pytest.fixture
def cache(tmp_path, monkeypatch):
    monkeypatch.setattr(art_fetch, "CACHE_DIR", str(tmp_path / "cache"))
    return tmp_path / "cache"


def test_declared_oversize_download_is_refused_unread(cache, monkeypatch):
    monkeypatch.setattr(art_fetch.requests, "get", lambda *a, **k: Download(b"", art_fetch.MAX_BYTES + 1))
    with pytest.raises(art_fetch.TooLarge):
        art_fetch.fetch_art("https://example.test/huge.jpg")


def test_undeclared_oversize_download_stops_at_the_cap(cache, monkeypatch):
    monkeypatch.setattr(art_fetch, "MAX_BYTES", 1000)
    monkeypatch.setattr(art_fetch.requests, "get", lambda *a, **k: Download(b"x" * 5000))
    with pytest.raises(art_fetch.TooLarge):
        art_fetch.fetch_art("https://example.test/stream.jpg")
    assert not any(cache.iterdir())


def test_too_many_pixels_are_refused_before_the_decode(cache, monkeypatch):
    monkeypatch.setattr(art_fetch, "MAX_PIXELS", 100 * 100)
    buffer = io.BytesIO()
    Image.new("RGB", (200, 200), "blue").save(buffer, "PNG")
    monkeypatch.setattr(art_fetch.requests, "get", lambda *a, **k: Download(buffer.getvalue()))
    with pytest.raises(art_fetch.TooLarge):
        art_fetch.fetch_art("https://example.test/big.png")


def test_a_large_jpeg_decodes_at_a_reduced_scale(cache, monkeypatch):
    buffer = io.BytesIO()
    Image.new("RGB", (4096, 4096), "orange").save(buffer, "JPEG")
    monkeypatch.setattr(art_fetch.requests, "get", lambda *a, **k: Download(buffer.getvalue()))
    img = art_fetch.fetch_art("https://example.test/photo.jpg")
    assert 1024 <= img.width < 4096 and img.getpixel((10, 10))[0] > 200


# ---- teach: the render loop never waits, learning merges only new rows ---------------------

@pytest.fixture
def marks(monkeypatch):
    state = {"hs": np.arange(30, dtype=np.uint32), "ts": np.arange(30, dtype=np.int32)}
    monkeypatch.setattr("brain.nowplaying.teach.fingerprint", lambda pcm: (state["hs"], state["ts"]))
    return state


def learn(lib, title="One"):
    return lib.learn(np.zeros(RATE * 4, dtype=np.int16), title, "Artist")


def test_render_loop_reads_do_not_wait_for_learning(tmp_path, marks):
    lib = Library(str(tmp_path))
    learn(lib)
    held, done = threading.Event(), threading.Event()
    def hold():
        with lib._lock:
            held.set()
            done.wait(3)
    thread = threading.Thread(target=hold)
    thread.start()
    assert held.wait(3)
    try:
        t0 = time.monotonic()
        assert lib.has("One", "Artist") and not lib.has("One", "Artist", "ear")
        assert lib.generation == 0
        assert time.monotonic() - t0 < 0.5
    finally:
        done.set()
        thread.join(3)


def test_learning_merges_new_rows_sorted_and_without_duplicates(tmp_path, marks):
    lib = Library(str(tmp_path))
    marks["hs"] = np.array([50, 10, 10, 30] * 8, dtype=np.uint32)
    marks["ts"] = np.array([1, 2, 2, 3] * 8, dtype=np.int32)
    learn(lib)
    assert lib._hash.tolist() == [10, 30, 50]
    marks["hs"] = np.array([40, 10, 20] * 10, dtype=np.uint32)
    marks["ts"] = np.array([4, 2, 5] * 10, dtype=np.int32)
    learn(lib)                                   # (10, 2) is already known
    assert lib._hash.tolist() == sorted(lib._hash.tolist()) == [10, 20, 30, 40, 50]
    assert lib.listing()[0]["landmarks"] == 5
    learn(lib, "Two")                            # the same rows for another song are its own
    assert lib.status()["landmarks"] == 8
    assert np.all(lib._hash[1:] >= lib._hash[:-1])
    reloaded = Library(str(tmp_path))
    assert reloaded.status()["landmarks"] == 8 and reloaded.problem is None


def test_room_learning_failures_are_not_left_on_the_page(tmp_path, marks):
    def offline(*_):
        raise RuntimeError("The preview catalogue isn't answering.")
    teacher = Teacher(Library(str(tmp_path)), object(), fetch=offline)
    now = SimpleNamespace(title="One", artist="Artist", album="", art_url=None, duration_ms=None)
    teacher._begin(now.title, now.artist)
    teacher._run(teacher._learn_preview, now)
    assert teacher.status()["problem"] is None and teacher.status()["learning"] is None


def test_a_preview_too_short_to_learn_says_so(tmp_path, marks):
    marks["hs"] = np.arange(5, dtype=np.uint32)
    marks["ts"] = np.arange(5, dtype=np.int32)
    teacher = Teacher(Library(str(tmp_path)), object(),
                      fetch=lambda *_: (np.zeros(RATE * 4, dtype=np.int16), {}))
    with pytest.raises(TeachTooShort, match="enough distinct sound"):
        teacher.learn_named("One", "Artist")
    assert "enough distinct sound" in teacher.status()["problem"]


def test_an_unreadable_library_reports_a_sentence(tmp_path):
    (tmp_path / "library.npz").write_bytes(b"broken snapshot")
    lib = Library(str(tmp_path))
    assert lib.problem.startswith("The saved song library could not be read.")
    assert "Bad" not in lib.problem and "zip" not in lib.problem.lower()


def test_voice_teaching_reads_out_why_it_could_not(tmp_path, marks):
    class Busy:
        def learn_named(self, title, artist):
            raise TeachTooShort("The preview did not contain enough distinct sound to learn. Try another recording.")
    v = Voice(FakeCtrl(), FakeWake(), FakeTranscriber("x"), asker=FakeAsker("x"), teacher=Busy(),
              log=lambda _: None)
    assert v.say("teach this, it is nights by frank ocean")
    settle(v, "answering")
    assert "enough distinct sound" in v.last_answer


# ---- the voice: drawing starts and opens; notes carry no old colours -----------------------

def test_voice_drawing_starts_the_studio_and_frees_the_voice():
    ctrl = FakeCtrl()
    started = []
    ctrl.imaginer = SimpleNamespace(begin=lambda prompt: started.append(prompt) or {"accepted": True})
    v = Voice(ctrl, FakeWake(), FakeTranscriber("x"), asker=FakeAsker("x"), log=lambda _: None)
    assert v.say("draw a purple elephant")
    settle(v, "idle")
    assert started == ["purple elephant"]
    assert ctrl.transition is not None and ctrl.transition[0] == "open"


def test_voice_drawing_refusal_is_read_out():
    ctrl = FakeCtrl()
    ctrl.imaginer = SimpleNamespace(begin=lambda prompt: {"error": "The current picture is still being drawn.", "code": "busy"})
    v = Voice(ctrl, FakeWake(), FakeTranscriber("x"), asker=FakeAsker("x"), log=lambda _: None)
    v.say("draw a purple elephant")
    settle(v, "answering")
    assert v.last_answer == "The current picture is still being drawn."


def test_voice_note_and_remote_info_clear_message_colours():
    ctrl = FakeCtrl()
    v = Voice(ctrl, FakeWake(), FakeTranscriber("x"), asker=FakeAsker("x"), log=lambda _: None)
    v.say("note: back at six")
    settle(v, "idle")
    assert ctrl.applied[-1]["ticker_colors"] == [] and ctrl.applied[-1]["mode"] == "ticker"
    hk = bridge()
    hk.ctrl.now_showing = {"title": "Nights", "artist": "Frank Ocean"}
    hk._tv_key(K_INFO)
    assert hk.ctrl.changes[-1]["ticker_colors"] == [] and hk.ctrl.changes[-1]["ticker_text"] == "Nights - Frank Ocean"


# ---- ListenBrainz reading: checks itself, and a missing user is not asked every 5 s --------

def join_checks():
    for thread in threading.enumerate():
        if thread.name == "listenbrainz-check":
            thread.join(3)


def test_a_saved_username_is_checked_while_another_source_plays(monkeypatch):
    asked = []
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get",
                        lambda url, **k: asked.append(url) or Response(code=404))
    source = ListenBrainzSource("mistyped")
    assert source.status()["read_state"] == "checking"
    join_checks()
    assert source.status()["read_state"] == "refused"
    assert len(asked) == 1


def test_a_missing_user_waits_but_an_explicit_check_does_not(monkeypatch):
    asked = []
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get",
                        lambda url, **k: asked.append(url) or Response(code=404))
    source = ListenBrainzSource("mistyped")
    source.get_current()
    assert source._backoff_until - time.monotonic() > MISSING_USER_S - 5
    source._asked_at = 0
    assert source.get_current() is None and len(asked) == 1
    assert source.retry() is True
    join_checks()
    assert len(asked) == 2


def test_a_playing_report_that_ages_out_is_ready_not_checking(monkeypatch):
    clock = [100.0]
    monkeypatch.setattr("brain.nowplaying.listenbrainz.time.monotonic", lambda: clock[0])
    monkeypatch.setattr("brain.nowplaying.listenbrainz.requests.get", lambda *a, **k: Response(listen()))
    source = ListenBrainzSource("listener")
    monkeypatch.setattr(source, "_art", lambda *args: None)
    assert source.get_current() is not None
    clock[0] += 31
    assert source.status()["read_state"] == "ready"
    assert not any(t.name == "listenbrainz-check" for t in threading.enumerate())


# ---- Discogs: reads that trying again cannot fix say what will -----------------------------

@pytest.mark.parametrize("error,words", [
    (LookupError("not on Discogs"), "could not find this username"),
    (requests.HTTPError(response=SimpleNamespace(status_code=403)), "private to another account"),
    (PermissionError("Discogs rejected the token"), "rejected the token"),
    (KeyError("releases"), "Try again"),
])
def test_discogs_read_problems_name_the_fix(tmp_path, error, words):
    def fetch(*_):
        raise error
    shelf = create_shelf(tmp_path, fetch)
    shelf.sync()
    assert words in shelf.problem and ";" not in shelf.problem


# ---- posters: a phone lookup is not a poster the Mac found ---------------------------------

TV = {"results": [{"id": 95396, "name": "Severance", "first_air_date": "2022-02-17",
                   "poster_path": "/poster.jpg", "overview": "Work and life."}]}


def test_forced_lookups_do_not_change_the_count_or_history(tmp_path):
    calls, clock = [], [1000.0]
    posters = Posters(api_key="a" * 32, path=str(tmp_path / "posters.json"),
                      fetch=lambda *a: calls.append(a) or TV, clock=lambda: clock[0])
    for _ in range(3):
        assert posters.lookup("Severance", force=True)
        clock[0] += 5                            # past the pause between checks
    status = posters.status()
    assert status["posters"] == 0 and status["last"] is None and status["known"] == 0
    assert status["checked"]["title"] == "Severance"
    asked = len(calls)
    posters.lookup("Severance")                  # the Mac's own lookup still asks and counts
    assert len(calls) > asked
    assert posters.status()["posters"] == 1 and posters.status()["last"]["title"] == "Severance"
    assert json.load(open(tmp_path / "posters.json"))["count"] == 1
