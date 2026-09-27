"""Contexto's semantic ranks, receipts, reveal integrity and shared composition."""
import math

import numpy as np
import pytest

from brain.games.contexto import Contexto, GROUND, PAPER, TRACK, colour_of, proximity_of, ranking, vectors


def make_game(word="guitar", players=None):
    game = Contexto(None, {"word": word}, players or ["You"])
    game.setup()
    return game


@pytest.mark.parametrize("move", [None, [], 9, {}, {"word": None}, {"word": True}, {"word": ["piano"]},
                                 {"word": "two words"}, {"word": "piano!"}, {"word": "école"},
                                 {"word": "x" * 33}, {"give_up": "yes"}, {"give_up": 1},
                                 {"give_up": False}, {"give_up": True, "word": "piano"},
                                 {"word": "piano", "guess": "guitar"}])
def test_malformed_moves_do_not_change_or_reveal_the_game(move):
    game = make_game()
    before = game.public()
    assert game.apply(move, "You")["error"]
    assert game.public() == before
    assert game.state()["secret"] is None


@pytest.mark.parametrize("options", [{"word": None}, {"word": 123}, {"word": []}, {"word": "not a word"},
                                     {"seed": True}, {"seed": {}}, {"seed": 1.5}])
def test_invalid_setup_options_fail_before_a_round_is_playable(options):
    with pytest.raises(ValueError):
        Contexto(None, options).setup()


def test_duplicate_is_acknowledged_and_highlighted_without_spending_a_try():
    game = make_game(players=["Ada", "Max"])
    first = game.apply({"word": "piano"}, "Ada")
    game.apply({"word": "banana"}, "Max")
    previous = game.public()
    again = game.apply({"word": "  PIANO  "}, "Max")
    after = game.public()
    assert again["again"] and again["receipt"] == previous["receipt"] + 1
    assert after["last"] == {"word": "piano", "rank": first["rank"], "again": True}
    assert after["seq"] == previous["seq"] + 1
    assert after["count"] == 2 and after["best"] == first["rank"]
    assert after["guesses"] == previous["guesses"]
    assert after["guesses"][0]["who"] == "Ada"


def test_rejected_word_does_not_publish_a_false_receipt():
    game = make_game()
    game.apply({"word": "piano"}, "You")
    before = game.public()
    assert game.apply({"word": "zzzq"}, "You")["error"]
    assert game.public() == before


def test_history_keeps_both_closeness_order_and_original_chronology():
    game = make_game()
    for word in ("banana", "music", "piano"):
        game.apply({"word": word}, "You")
    state = game.state()
    assert [item["rank"] for item in state["guesses"]] == sorted(item["rank"] for item in state["guesses"])
    assert [item["word"] for item in sorted(state["guesses"], key=lambda item: item["order"])] == ["banana", "music", "piano"]
    assert state["best_word"] == "piano"
    assert state["last"]["word"] == "piano" and state["receipt"] == 3
    assert state["vocabulary"] == 20_000 and state["band"] == "Close"
    assert 0 < state["proximity"] < 1


@pytest.mark.parametrize("win", [False, True])
def test_completion_is_immutable_and_reveal_never_fabricates_a_winning_guess(win):
    game = make_game(players=["Ada", "Max"])
    game.apply({"word": "piano"}, "Ada")
    if win:
        game.apply({"word": "guitar"}, "Max")
    else:
        game.apply({"give_up": True}, "Max")
    before = game.public()
    assert game.over and game.won == win and before["secret"] == "guitar"
    assert before["gave_up"] != win
    assert before["count"] == (2 if win else 1)
    assert before["winner"] == ("Max" if win else None)
    assert before["last"]["word"] == ("guitar" if win else "piano")
    for move in ({"word": "music"}, {"give_up": True}, {"word": "guitar"}, []):
        assert game.apply(move, "Ada")["error"]
    assert game.hear("reveal", "Ada")["error"]
    assert game.hear("piano", "Ada")["error"]
    assert game.public() == before


def test_voice_ignores_conversation_and_accepts_supported_word_phrases():
    game = make_game()
    for text in (None, 99, "the weather is nice", "piano and guitar"):
        assert game.hear(text, "You") is None
    assert game.hear("Maybe PIANO!", "You")["rank"] < 60
    assert game.hear("give up", "You")["secret"] == "guitar"


def test_answer_rank_is_one_even_when_another_vector_is_identical(monkeypatch):
    import brain.games.contexto as module
    vocabulary = ["alias", "answer", "other"]
    matrix = np.array([[1, 0], [1, 0], [0, 1]], dtype=np.float32)
    monkeypatch.setattr(module, "vectors", lambda: (vocabulary, matrix, {w: i for i, w in enumerate(vocabulary)}))
    ranks = module.ranking("answer")
    assert list(ranks) == [2, 1, 3]
    game = make_game("answer")
    assert game.apply({"word": "alias"}, "You")["rank"] == 2 and not game.over
    assert game.apply({"word": "answer"}, "You")["rank"] == 1 and game.won


def test_all_local_ranks_are_unique_and_source_vectors_are_normalized():
    vocabulary, matrix, _ = vectors()
    np.testing.assert_allclose(np.linalg.norm(matrix, axis=1), 1, atol=1e-6)
    np.testing.assert_array_equal(np.sort(ranking("guitar")), np.arange(1, len(vocabulary) + 1))
    assert not matrix.flags.writeable


def test_dial_moves_monotonically_toward_one_and_handles_no_guess():
    levels = [proximity_of(rank, 20_000) for rank in (20_000, 1500, 300, 6, 1)]
    assert levels == sorted(levels) and levels[0] == 0 and levels[-1] == 1
    assert proximity_of(None, 20_000) == 0
    assert colour_of(300) != colour_of(301) and colour_of(1500) != colour_of(1501)


@pytest.mark.parametrize("size", [64, 192, 512])
@pytest.mark.parametrize("state", ["empty", "far", "near", "won", "revealed"])
def test_same_dial_geometry_and_legible_unclipped_labels_at_every_resolution(monkeypatch, size, state):
    import brain.games.contexto as module
    game = make_game()
    if state != "empty": game.apply({"word": "banana"}, "You")
    if state in ("near", "won", "revealed"): game.apply({"word": "piano"}, "You")
    if state == "won": game.apply({"word": "guitar"}, "You")
    if state == "revealed": game.apply({"give_up": True}, "You")
    lines, labels, words = [], [], []
    original_line, original_text, original_scroll = module.line, module.text_centred, module.text_scrolled
    def draw_line(canvas, p0, p1, colour, width):
        lines.append((p0, p1, colour, width))
        original_line(canvas, p0, p1, colour, width)
    def draw_text(canvas, label, cx, y, colour, scale):
        labels.append((label, cx - module.text_width(label, scale) / 2, y, module.text_width(label, scale), 7 * scale))
        original_text(canvas, label, cx, y, colour, scale)
    def scroll_word(canvas, word, x, y, width, t, colour, scale, **kwargs):
        words.append((word, x, y, width, 7 * scale))
        original_scroll(canvas, word, x, y, width, t, colour, scale, **kwargs)
    monkeypatch.setattr(module, "line", draw_line)
    monkeypatch.setattr(module, "text_centred", draw_text)
    monkeypatch.setattr(module, "text_scrolled", scroll_word)
    frame = game.frame_at(size, 0)
    assert frame.shape == (size, size, 3) and frame.dtype == np.uint8
    assert len(lines) == 41
    for i, (inner, outer, colour, width) in enumerate(lines):
        angle = math.radians(150 + 240 * i / 40)
        assert inner == pytest.approx((size * (.5 + .292 * math.cos(angle)), size * (.39 + .292 * math.sin(angle))))
        assert outer == pytest.approx((size * (.5 + .325 * math.cos(angle)), size * (.39 + .325 * math.sin(angle))))
        assert all(width <= coordinate <= size - width for point in (inner, outer) for coordinate in point)
    assert all(x >= 0 and y >= 0 and x + width <= size and y + height <= size for _, x, y, width, height in labels + words)
    assert words[0][0] == ("GUITAR" if game.over else "PIANO" if state == "near" else "BANANA" if state == "far" else "GUESS" if size == 64 else "FIRST WORD")
    if game.over:
        assert all(colour != TRACK for _, _, colour, _ in lines)
        assert not np.all(frame == GROUND)
    if state == "revealed":
        assert all(colour == PAPER for _, _, colour, _ in lines)


def test_long_word_remains_fully_available_in_masked_wall_label(monkeypatch):
    import brain.games.contexto as module
    longest = max(vectors()[0], key=len)
    game = make_game()
    game.apply({"word": longest}, "You")
    captured = []
    original = module.text_scrolled
    def scroll(canvas, text, *args, **kwargs):
        captured.append(text)
        original(canvas, text, *args, **kwargs)
    monkeypatch.setattr(module, "text_scrolled", scroll)
    first = game.frame_at(64, 0)
    later = game.frame_at(64, 4)
    assert captured == [longest.upper()] * 2
    assert np.any(first[44:53] != later[44:53])
