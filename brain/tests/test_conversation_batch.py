"""Provider ownership, acknowledged conversation turns and immutable drawing rounds."""
import threading
import time
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from brain.games import twentyq
from brain.games.pictionary import Pictionary, accepted_names
from brain.games.host import GameHost
from brain.tests.test_games import FakeCtrl


def wait_for(condition, timeout=2):
    limit = time.monotonic() + timeout
    while not condition():
        if time.monotonic() >= limit:
            raise AssertionError("background operation did not settle")
        time.sleep(.002)


def question_game(monkeypatch, provider=None, host=None):
    monkeypatch.setattr(twentyq, "ask_claude", provider or (lambda asker, history: {"question": f"Question {len(history) + 1}?"}))
    if host:
        host.start("twentyq", {"asker": SimpleNamespace(ready=True)})
        game = host.game
    else:
        game = twentyq.TwentyQuestions(None, {"asker": SimpleNamespace(ready=True)})
        game.setup()
    wait_for(lambda: not game.thinking)
    return game


class Drawer:
    ready = True
    def draw(self, *args, on_partial=None, **kwargs):
        return Image.new("RGB", (640, 640), (46, 92, 117))


def picture_game(drawer=None, word="elephant", seconds=60, host=None):
    options = {"imaginer": drawer or Drawer(), "word": word, "seconds": seconds}
    if host:
        host.start("pictionary", options)
        return host.game
    game = Pictionary(None, options)
    game.setup()
    return game


def test_twentyq_answer_returns_while_provider_is_blocked_and_host_remains_responsive(tmp_path, monkeypatch):
    entered, release = threading.Event(), threading.Event()
    def provider(asker, history):
        if history:
            entered.set(); assert release.wait(2)
        return {"question": "Is it alive?" if not history else "Is it an animal?"}
    host = GameHost(FakeCtrl(), str(tmp_path / "games.json"))
    game = question_game(monkeypatch, provider, host)
    token = game.question_id
    result = host.move(None, {"answer": "yes", "question_id": token})
    try:
        assert entered.wait(1) and result["answered"] == "yes" and result["game"]["thinking"]
        statuses = []
        worker = threading.Thread(target=lambda: statuses.append(host.status()), daemon=True)
        worker.start(); worker.join(.3)
        assert not worker.is_alive() and statuses[0]["game"]["history"] == [{"q": "Is it alive?", "a": "yes"}]
        assert host.move(None, {"answer": "no", "question_id": token})["error"]
        assert host.hear("yes")["error"] and len(game.history) == 1
    finally:
        release.set()
    wait_for(lambda: not game.thinking)
    assert game.current == "Is it an animal?" and game.question_id != token
    assert host.move(None, {"answer": "yes", "question_id": token})["error"]
    assert game.receipt == 1


def test_twentyq_late_provider_cannot_publish_to_an_ended_or_replaced_game(tmp_path, monkeypatch):
    entered, release, returned = threading.Event(), threading.Event(), threading.Event()
    def provider(asker, history):
        if history:
            entered.set(); assert release.wait(2); returned.set()
        return {"question": "Is it alive?" if not history else "Late question?"}
    host = GameHost(FakeCtrl(), str(tmp_path / "games.json"))
    old = question_game(monkeypatch, provider, host)
    host.move(None, {"answer": "yes", "question_id": old.question_id})
    assert entered.wait(1)
    host.end()
    before = host.status()
    release.set(); assert returned.wait(1)
    time.sleep(.02)
    assert host.status() == before and old.current is None


def test_twentyq_error_is_retryable_without_spending_an_answer_and_retry_is_coalesced(monkeypatch):
    entered, release = threading.Event(), threading.Event()
    calls = []
    def provider(asker, history):
        calls.append(list(history))
        if len(calls) == 1: raise RuntimeError("provider unavailable")
        entered.set(); assert release.wait(2)
        return {"guess": "a lighthouse"}
    game = question_game(monkeypatch, provider)
    assert not game.over and game.state()["can_retry"] and game.history == []
    assert game.apply({"retry": True}, "You")["retrying"]
    try:
        assert entered.wait(1)
        assert game.apply({"retry": True}, "You")["error"]
        assert game.apply({"answer": "yes"}, "You")["error"]
    finally: release.set()
    wait_for(lambda: not game.thinking)
    assert len(calls) == 2 and calls == [[], []]
    result = game.apply({"answer": "yes", "question_id": game.question_id}, "You")
    assert result["got_it"] and game.won and game.receipt == 1


@pytest.mark.parametrize("move", [None, [], {}, {"answer": True}, {"answer": 7}, {"answer": "sometimes"},
                                 {"answer": "yes", "question_id": None}, {"answer": "yes", "question_id": 2},
                                 {"answer": "yes", "question_id": "stale"}, {"retry": "true"},
                                 {"retry": 1}, {"answer": "yes", "extra": True}])
def test_twentyq_invalid_input_keeps_active_question_and_receipt(monkeypatch, move):
    game = question_game(monkeypatch)
    before = game.public()
    assert game.apply(move, "You")["error"]
    assert game.public() == before


@pytest.mark.parametrize("turn", [None, {}, {"question": 7}, {"guess": []}, {"question": " "},
                                  {"question": "Is it alive?", "guess": "cat"}, {"question": "a" * 181}])
def test_twentyq_malformed_provider_result_remains_recoverable(monkeypatch, turn):
    game = question_game(monkeypatch, lambda asker, history: turn)
    assert game.state()["phase"] == "error" and not game.over and game.current is None


def test_twentyq_repeated_provider_question_is_not_asked_or_counted_twice(monkeypatch):
    game = question_game(monkeypatch, lambda asker, history: {"question": "Is it alive?"})
    assert game.apply({"answer": "no", "question_id": game.question_id}, "You")["answered"] == "no"
    wait_for(lambda: not game.thinking)
    assert game.state()["can_retry"] and len(game.history) == game.receipt == 1


def test_twentyq_twentieth_answer_finishes_without_a_twenty_first_provider_call(monkeypatch):
    calls = []
    def provider(asker, history):
        calls.append(len(history)); return {"question": f"Question {len(history) + 1}?"}
    game = question_game(monkeypatch, provider)
    for _ in range(20):
        assert "error" not in game.apply({"answer": "no", "question_id": game.question_id}, "You")
        wait_for(lambda: not game.thinking)
    assert calls == list(range(20)) and game.over and not game.won
    assert game.state()["number"] == 20
    before = game.public()
    assert game.apply({"retry": True}, "You")["error"]
    assert game.event("knock", {}) is False and game.public() == before


def test_pictionary_partial_is_a_512_master_and_timer_starts_only_on_first_picture():
    entered, release_partial, partial_done, release_final = [threading.Event() for _ in range(4)]
    class Streaming(Drawer):
        def draw(self, *args, on_partial=None, **kwargs):
            entered.set(); assert release_partial.wait(2)
            on_partial(Image.new("RGB", (1024, 1024), "red")); partial_done.set()
            assert release_final.wait(2)
            return Image.new("RGB", (1024, 1024), "blue")
    game = picture_game(Streaming()); assert entered.wait(1)
    now = [100.0]; game._clock = lambda: now[0]
    try:
        assert game.t0 is None and game.state()["remaining"] == 60
        release_partial.set(); assert partial_done.wait(1)
        assert game.picture.size == (512, 512) and game.t0 == 100 and game.drawing
        now[0] = 109
        assert game.state()["elapsed"] == 9 and game.apply({"guess": "giraffe"}, "You")["hit"] is False
        release_final.set(); wait_for(lambda: not game.drawing)
        assert game.t0 == 100 and game.state()["elapsed"] == 9 and game.drawing_revision == 2
        assert game.picture.getpixel((256, 256)) == (0, 0, 255)
    finally:
        release_partial.set(); release_final.set()


def test_pictionary_success_freezes_partial_and_ignores_late_final_and_provider_error():
    partial_done, release = threading.Event(), threading.Event()
    class Streaming(Drawer):
        def draw(self, *args, on_partial=None, **kwargs):
            on_partial(Image.new("RGB", (512, 512), "red")); partial_done.set()
            assert release.wait(2)
            on_partial(Image.new("RGB", (512, 512), "blue"))
            raise RuntimeError("late provider failure")
    game = picture_game(Streaming()); assert partial_done.wait(1)
    now = [game.t0 + 4]; game._clock = lambda: now[0]
    assert game.apply({"guess": "elephants"}, "You")["hit"]
    before = game.public(); frame = game.frame_at(512, 0)
    now[0] += 90; release.set(); time.sleep(.04)
    assert game.public() == before and game.state()["elapsed"] == 4
    np.testing.assert_array_equal(game.frame_at(512, 90), frame)
    assert game.problem is None and not game.drawing


def test_pictionary_deadline_wins_before_a_late_correct_guess():
    game = picture_game(seconds=5); wait_for(lambda: not game.drawing)
    game._clock = lambda: game.t0 + 5
    assert game.apply({"guess": "elephant"}, "You")["error"]
    assert game.over and not game.won and game.receipt == 0 and game.state()["elapsed"] == 5


def test_pictionary_error_without_art_retries_without_timer_or_guess_reset():
    calls = []
    class Flaky(Drawer):
        def draw(self, *args, on_partial=None, **kwargs):
            calls.append(1)
            if len(calls) == 1: raise RuntimeError("offline")
            return super().draw(*args, **kwargs)
    game = picture_game(Flaky()); wait_for(lambda: not game.drawing)
    assert game.problem and game.state()["can_retry"] and not game.over and game.t0 is None
    assert game.apply({"retry": True}, "You")["retrying"]
    wait_for(lambda: not game.drawing)
    assert len(calls) == 2 and game.problem is None and game.picture is not None and game.receipt == 0


def test_pictionary_failed_final_keeps_usable_sketch_and_clock():
    class PartialFailure(Drawer):
        def draw(self, *args, on_partial=None, **kwargs):
            on_partial(Image.new("RGB", (512, 512), "red"))
            raise RuntimeError("stream broke")
    game = picture_game(PartialFailure()); wait_for(lambda: not game.drawing)
    assert not game.over and game.state()["phase"] == "playing" and not game.state()["can_retry"]
    assert game.apply({"guess": "elephant"}, "You")["hit"]


def test_pictionary_ended_worker_cannot_publish_to_wall_or_change_scores(tmp_path):
    entered, release, returned = threading.Event(), threading.Event(), threading.Event()
    class Slow(Drawer):
        def draw(self, *args, on_partial=None, **kwargs):
            entered.set(); assert release.wait(2)
            returned.set(); return super().draw(*args, **kwargs)
    host = GameHost(FakeCtrl(), str(tmp_path / "games.json"))
    game = picture_game(Slow(), host=host); assert entered.wait(1)
    host.end(); before = host.status()
    release.set(); assert returned.wait(1); time.sleep(.04)
    assert host.status() == before and game.picture is None


def test_pictionary_callback_after_final_cannot_reopen_drawing():
    callbacks = []
    class LatePartial(Drawer):
        def draw(self, *args, on_partial=None, **kwargs):
            callbacks.append(on_partial)
            return super().draw(*args, **kwargs)
    game = picture_game(LatePartial()); wait_for(lambda: not game.drawing)
    before = game.public(); pixel = game.picture.getpixel((10, 10))
    callbacks[0](Image.new("RGB", (512, 512), "red"))
    assert game.public() == before and game.picture.getpixel((10, 10)) == pixel


@pytest.mark.parametrize("guess", ["not elephant", "tiny elephants nearby", "eleph", "elephantine", "giraffe"])
def test_pictionary_requires_a_complete_name_not_a_substring(guess):
    game = picture_game(); wait_for(lambda: not game.drawing)
    assert game.apply({"guess": guess}, "You")["hit"] is False and not game.over


@pytest.mark.parametrize("word,accepted", [("elephant", "an elephant"), ("elephant", "ELEPHANTS"),
                                           ("butterfly", "butterflies"), ("compass", "compasses"),
                                           ("hot air balloon", "hot air balloons"), ("cactus", "cacti")])
def test_pictionary_accepts_normalized_whole_names_and_ordinary_plurals(word, accepted):
    game = picture_game(word=word); wait_for(lambda: not game.drawing)
    assert game.apply({"guess": accepted}, "You")["hit"]
    assert "compa" not in accepted_names("compass")


def test_pictionary_duplicate_and_invalid_guesses_do_not_publish_receipts():
    game = picture_game(); wait_for(lambda: not game.drawing)
    game.apply({"guess": "giraffe"}, "You")
    before = game.state()
    for move in (None, [], {}, {"guess": 3}, {"guess": True}, {"guess": "!"}, {"guess": "x" * 121},
                 {"guess": "giraffe"}, {"guess": "giraffe", "word": "elephant"}, {"retry": 1}):
        assert game.apply(move, "You")["error"]
    after = game.state()
    for key in ("guesses", "receipt", "guess_count", "last_guess"):
        assert after[key] == before[key]


@pytest.mark.parametrize("options", [{"seconds": True}, {"seconds": float("nan")}, {"seconds": 0},
                                     {"seconds": 301}, {"word": []}, {"word": ""}, {"word": "x" * 49},
                                     {"word": "a\nthing"}, {"seed": {}}])
def test_pictionary_invalid_options_fail_before_starting_a_provider(options):
    with pytest.raises(ValueError):
        Pictionary(None, {"imaginer": Drawer(), **options}).setup()


@pytest.mark.parametrize("size", [64, 192, 512])
def test_pictionary_finished_art_is_full_bleed_without_timer_or_result_banner(size):
    game = picture_game(); wait_for(lambda: not game.drawing)
    game.apply({"guess": "elephant"}, "You")
    frame = game.frame_at(size, 0)
    assert frame.shape == (size, size, 3)
    assert np.all(frame == (46, 92, 117))


@pytest.mark.parametrize("size", [64, 192, 512])
def test_twentyq_question_pages_keep_every_line_available_and_within_frame(monkeypatch, size):
    game = question_game(monkeypatch, lambda asker, history: {"question": "Does it live in the sea, in the deep parts, far from shore?"})
    labels = []
    original = twentyq.text_scrolled
    def label(canvas, text, x, y, width, t, color, scale):
        labels.append((text, x, y, width, scale))
        original(canvas, text, x, y, width, t, color, scale)
    monkeypatch.setattr(twentyq, "text_scrolled", label)
    for second in (0, 4, 8, 12, 16, 20):
        frame = game.frame_at(size, second)
        assert frame.shape == (size, size, 3) and frame.dtype == np.uint8
    assert all(x >= 0 and x + width <= size and y >= 0 and y + scale * 7 < size * .88 for _, x, y, width, scale in labels)
    shown = " ".join(text for text, *_ in labels)
    assert all(word.strip(",?").upper() in shown for word in game.current.split())
