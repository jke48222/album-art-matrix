"""Listening-game boundaries: transport, answer receipts, clocks and real RGB."""
import copy
import math
from types import SimpleNamespace

import numpy as np
import pytest
from PIL import Image

from brain.games.heardle import Heardle
from brain.games.quiz import Quiz, SHOW_ANSWER_S

SONG = {"title": "Nights", "artist": "Frank Ocean", "preview": "https://example.test/nights.m4a"}


def heardle(**options):
    game = Heardle(None, {**SONG, **options}, ["A", "B"])
    game.setup()
    now = [0.0]
    game._clock = lambda: now[0]
    return game, now


def quiz(**options):
    game = Quiz(None, {"set": 1, **options}, ["A", "B"])
    game.setup()
    now = [0.0]
    game._clock = lambda: now[0]
    game.t_q = 0.0
    return game, now


@pytest.mark.parametrize("text", ["night", "nights maybe", "not nights", "Nights [wrong]", "Nights (wrong)"])
def test_heardle_requires_complete_title(text):
    game, _ = heardle()
    assert not game.guess(text, "A")["hit"]
    assert not game.over


def test_heardle_winning_receipt_and_terminal_immutability():
    game, _ = heardle(title="Beyoncé’s Song")
    assert game.guess("Beyonces Song!", "A")["hit"]
    state = copy.deepcopy(game.public())
    assert state["tries"] == [{"text": "Beyonces Song!", "who": "A", "skipped": False, "hit": True}]
    for move in ({"played": True}, {"played": False}, {"skip": True}, {"guess": "wrong"}):
        assert "error" in game.apply(move, "A")
    assert game.public() == state


@pytest.mark.parametrize("move", [{"skip": "true"}, {"skip": False}, {"played": "yes"}, {"played": True, "position": math.nan}, {"played": True, "position": True}, {"played": True, "position": 2}, {"guess": []}, {"guess": 3}, {"guess": " "}, {"guess": "x" * 121}])
def test_heardle_rejects_invalid_moves_without_state_change(move):
    game, _ = heardle()
    before = copy.deepcopy(game.public())
    assert "error" in game.apply(move, "A")
    assert game.public() == before


def test_heardle_turn_step_and_real_clip_stop():
    game, now = heardle()
    assert "error" in game.apply({"guess": "Nights"}, "B")
    game.skip("A")
    assert "error" in game.apply({"played": True, "step": 0}, "B")
    assert not game.state()["playing"]
    game.apply({"played": True, "position": 0.75, "step": 1}, "B")
    assert game.state()["playback_position"] == .75
    now[0] += .25
    assert game.state()["playback_position"] == 1
    game.apply({"played": False, "step": 1, "position": 1}, "B")
    assert not game.state()["playing"]
    game.apply({"played": True, "step": 1, "position": 1}, "B")
    now[0] += 1
    assert not game.state()["playing"]
    assert not game.over and game.step == 1


def test_heardle_drawing_never_fetches_art(monkeypatch, tmp_path):
    source = Image.new("RGB", (512, 512), (30, 150, 200))
    path = tmp_path / "sleeve.png"
    source.save(path)
    game, _ = heardle(image=str(path))
    def unexpected(*args, **kwargs):
        raise AssertionError("rendering must never use the network")
    monkeypatch.setattr("brain.games.heardle.fetch_art", unexpected)
    game.guess("Nights", "A")
    for size in (64, 192, 512):
        assert np.array_equal(game.frame_at(size, 0), np.array(source.resize((size, size))))


@pytest.mark.parametrize("seconds", [True, "20", 0, 4.9, 121, math.nan, math.inf])
def test_quiz_finite_duration_contract(seconds):
    with pytest.raises(ValueError):
        quiz(seconds=seconds)


def test_quiz_strict_answer_and_hidden_correctness():
    game, _ = quiz()
    assert game.apply({"answer": "not Canberra", "question_id": 1}, "A")["right"] is False
    assert game.apply({"answer": "canberra", "question_id": 1}, "B")["right"] is True
    assert game.phase == "answer" and game.scores == {"A": 0, "B": 1}
    game, _ = quiz()
    game.apply({"answer": "Canberra", "question_id": 1}, "A")
    state = game.state()
    assert state["scores"]["A"] == 0 and state["answered"]["A"]["right"] is None
    assert state["answered"]["A"]["text"] == "Canberra"  # exact ACK receipt
    game.apply({"answer": "Sydney", "question_id": 1}, "B")
    assert game.state()["scores"]["A"] == 1 and game.state()["answered"]["A"]["right"] is True


def test_quiz_answer_at_deadline_and_stale_after_transition():
    game, now = quiz()
    now[0] = game.seconds
    assert "error" in game.apply({"answer": "Canberra", "question_id": 1}, "A")
    assert game.scores == {"A": 0, "B": 0} and game.phase == "answer"
    now[0] += SHOW_ANSWER_S
    assert "error" in game.answer("Canberra", "A", 1)
    assert game.question_id == 2 and not game.answered
    assert "error" in game.apply({"answer": "6", "question_id": 1}, "A")
    assert "error" in game.apply({"answer": "6"}, "A")
    assert game.apply({"answer": "6", "question_id": 2}, "A")["right"]


@pytest.mark.parametrize("answer", [None, True, [], {}, 2, "x" * 121, " ", "!!!"])
def test_quiz_invalid_answers_are_not_attempts(answer):
    game, _ = quiz()
    assert "error" in game.apply({"answer": answer, "question_id": 1}, "A")
    assert not game.answered and game.seq == 0


def test_quiz_rejects_unknown_player_and_bad_tokens():
    game, _ = quiz()
    for token in (None, True, 1.0, "1", -1, 999):
        assert "error" in game.apply({"answer": "Canberra", "question_id": token}, "A")
    assert "error" in game.answer("Canberra", "Stranger")
    assert not game.answered


def test_quiz_tie_and_terminal_receipt_are_stable():
    game, now = quiz()
    for i in range(10):
        answer = game.questions[i][1][0]
        game.apply({"answer": answer, "question_id": i + 1}, "A")
        game.apply({"answer": answer, "question_id": i + 1}, "B")
        now[0] += SHOW_ANSWER_S
        state = game.public()
    assert state["over"] and state["number"] == state["count"] == 10
    assert state["tied"] and state["leaders"] == ["A", "B"] and state["winner"] is None
    assert len(state["results"]) == 10 and state["results"][0]["answered"]["A"]["right"]
    frozen = copy.deepcopy(state)
    for move in ({"next": True}, {"answer": "6", "question_id": 11}):
        assert "error" in game.apply(move, "A")
    now[0] += 999
    assert game.public() == frozen


def test_quiz_seed_avoids_provider_and_malformed_round_falls_back():
    class Provider:
        ready = True
        def quiz_round(self, *args):
            raise AssertionError("deterministic games must not query providers")
    game = Quiz(SimpleNamespace(ctrl=SimpleNamespace(asker=Provider())), {"seed": 11})
    game.setup()
    assert len(game.questions) == 10
    assert not Quiz._valid_round(("bad", [("Q", [""])] * 10))
    assert not Quiz._valid_round(("bad", [("Q", [123])] * 10))


@pytest.mark.parametrize("factory", [heardle, quiz])
@pytest.mark.parametrize("size", [64, 192, 512])
def test_real_compositions_render_at_every_size(factory, size):
    game, _ = factory()
    frame = game.frame_at(size, 0)
    assert frame.shape == (size, size, 3) and frame.dtype == np.uint8
    assert ((frame[..., 0] > 180) & (frame[..., 1] > 150)).sum() > size
    # Visible text exists within the question/record content, not only its header.
    region = frame[round(size * .3):round(size * .85)]
    assert (region[..., 0] > 180).sum() > size // 2


def test_quiz_64_question_scrolls_and_eight_score_rows_fit():
    game, now = quiz()
    first = game.frame_at(64, 0)
    now[0] = 16
    last = game.frame_at(64, 0)
    assert not np.array_equal(first[19:55], last[19:55])
    game.players = list("ABCDEFGH")
    game.scores = dict.fromkeys(game.players, 1)
    game.leaders = list(game.players)
    game.over, game.phase = True, "done"
    final = game.frame_at(64, 0)
    for row in range(4):
        for column in range(2):
            block = final[17 + row * 11:24 + row * 11, 4 + column * 32:31 + column * 32]
            assert (block[..., 0] > 180).sum() > 5


def test_question_wrap_preserves_every_character():
    from brain.games.quiz import question_lines
    from brain.art.pixelfont import text_width
    value = "How many revolutions a minute does an LP turn at?"
    lines = question_lines(value, 56, 1)
    assert all(text_width(line) <= 56 for line in lines)
    assert "".join("".join(lines).split()) == "".join(value.split())


@pytest.mark.parametrize("preview", [2, "file:///tmp/song", "not a url", "https://"])
def test_heardle_rejects_unusable_preview(preview):
    with pytest.raises(ValueError):
        heardle(preview=preview)


def test_quiz_final_frame_crossing_reveal_deadline_is_coherent():
    game, _ = quiz()
    game.i = 9
    game.phase = "answer"
    game.t_q = 0
    times = iter([3.999, 4.001])
    game._clock = lambda: next(times, 4.001)
    first = game.frame_at(192, 0)
    assert first.shape == (192, 192, 3)
    assert not game.over  # one state snapshot owns this whole frame
    second = game.frame_at(192, 0)
    assert second.shape == (192, 192, 3)
    assert game.over
