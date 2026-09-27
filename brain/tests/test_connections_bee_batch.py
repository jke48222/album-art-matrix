"""Full-board geometry and acknowledged interactions for Connections and Bee."""
from types import SimpleNamespace

import numpy as np
import pytest

from brain.games.connections import Connections, COLOURS
from brain.games.spellingbee import SpellingBee, score_of


def connections():
    game = Connections(None, {"set": 0, "seed": 10}, ["You"])
    game.setup()
    return game


def bee():
    game = SpellingBee(None, {"seed": 1}, ["You"])
    game.setup()
    return game


def test_one_away_keeps_selected_words_for_a_one_word_correction():
    game = connections()
    attempt = game.groups[0][1][:3] + [game.groups[1][1][0]]
    result = game.apply({"words": attempt}, "You")
    assert result["one_away"] and game.picked == attempt and game.mistakes == 1
    game.apply({"pick": attempt[-1]}, "You")
    game.apply({"pick": game.groups[0][1][3]}, "You")
    result = game.apply({"submit": True}, "You")
    assert result["group"] == 0 and game.picked == [] and game.mistakes == 1


def test_repeating_wrong_selection_does_not_spend_a_second_mistake():
    game = connections()
    attempt = game.groups[0][1][:2] + game.groups[1][1][:2]
    game.apply({"words": attempt}, "You")
    assert game.apply({"submit": True}, "You")["error"] == "already tried"
    assert game.mistakes == 1 and game.picked == attempt


def test_connections_shuffle_preserves_selection_and_membership():
    game = connections()
    game.apply({"pick": game.words[0]}, "You")
    before, picked = set(game.words), list(game.picked)
    game.apply({"shuffle": True}, "You")
    assert set(game.words) == before and game.picked == picked
    previous = list(game.words)
    assert game.apply({"shuffle": False}, "You")["error"]
    assert game.words == previous


@pytest.mark.parametrize("bad", [[None] * 4, [(None, ["a", "b", "c", "d"])] * 4,
                                 [("Theme", [1, 2, 3, 4])] * 4, [(" ", ["a", "b", "c", "d"])] * 4,
                                 [("Theme", ["a", "a", "b", "c"])] * 4])
def test_invalid_provider_groups_fall_back_to_complete_bundled_set(bad):
    asker = SimpleNamespace(ready=True, connections_set=lambda seed: bad)
    host = SimpleNamespace(ctrl=SimpleNamespace(asker=asker))
    game = Connections(host, {"seed": 1}, ["You"])
    game.setup()
    assert len(game.groups) == 4 and len(set(game.words)) == 16


@pytest.mark.parametrize("size", [64, 192, 512])
def test_all_sixteen_connection_tiles_are_drawn_in_four_columns_inside_canvas(monkeypatch, size):
    import brain.games.connections as module
    game = connections()
    boxes, labels = [], []
    original_tile, original_text = module.tile, module.text_scrolled
    def capture_tile(canvas, x, y, width, height, *args, **kwargs):
        boxes.append((x, y, width, height))
        return original_tile(canvas, x, y, width, height, *args, **kwargs)
    def capture_text(canvas, label, *args, **kwargs):
        labels.append(label)
        return original_text(canvas, label, *args, **kwargs)
    monkeypatch.setattr(module, "tile", capture_tile)
    monkeypatch.setattr(module, "text_scrolled", capture_text)
    frame = game.frame_at(size, 2)
    assert frame.dtype == np.uint8 and frame.shape == (size, size, 3)
    assert len(boxes) == 16 and len({box[0] for box in boxes}) == 4 and len({box[1] for box in boxes}) == 4
    assert set(labels) == {word.upper() for word in game.words}
    assert all(x >= 0 and y >= 0 and x + width <= size and y + height < size - 7 for x, y, width, height in boxes)


@pytest.mark.parametrize("size", [64, 192, 512])
def test_completed_connections_reveals_every_group_without_overlay(monkeypatch, size):
    import brain.games.connections as module
    game = connections()
    game.apply({"words": game.groups[0][1]}, "You")
    a, b = game.groups[1][1], game.groups[2][1]
    for i in range(4):
        game.apply({"words": [a[i], a[(i + 1) % 4], b[i], b[(i + 2) % 4]]}, "You")
    assert game.over and not game.won
    assert [g["solved"] for g in game.state()["groups"]] == [True, False, False, False]
    assert game.picked == []
    rendered = []
    original = module.tile
    def capture(canvas, x, y, width, height, color, *args, **kwargs):
        rendered.append((y, height, color))
        return original(canvas, x, y, width, height, color, *args, **kwargs)
    monkeypatch.setattr(module, "tile", capture)
    frame = game.frame_at(size, 10)
    assert [color for _, _, color in rendered] == COLOURS
    for y, height, color in rendered:
        assert np.any(np.all(frame[y:y+height] == color, axis=-1))
    assert game.apply({"pick": a[0]}, "You")["error"]


def test_bee_shuffle_is_a_real_acknowledged_reorder_not_a_new_puzzle():
    game = bee()
    word = game.answers[0]
    game.apply({"word": word}, "You")
    old = (game.centre, set(game.others), list(game.answers), list(game.found), game.points)
    previous = game.others
    assert game.apply({"shuffle": True}, "You") == {"shuffled": True}
    assert game.others != previous
    assert (game.centre, set(game.others), list(game.answers), list(game.found), game.points) == old


def test_bee_word_receipts_include_actual_points_and_pangram_status():
    game = bee()
    word = game.pangrams[0]
    game.apply({"word": word}, "You")
    state = game.state()
    assert state["found"][0] == {"word": word, "who": "You", "points": len(word) + 7, "pangram": True}
    assert state["found_pangrams"] == 1
    assert state["next_points"] >= game.points and state["next_rank"]
    assert 0 <= state["rank_progress"] <= 1


def test_bee_rejected_word_is_not_in_acknowledged_found_ledger():
    game = bee()
    before = game.state()["found"]
    assert game.apply({"word": game.centre * 4}, "You")["error"]
    assert game.state()["found"] == before and game.points == 0


def test_bee_duplicate_word_does_not_inflate_score_or_ledger():
    game = bee()
    word = game.answers[0]
    game.apply({"word": word}, "You")
    assert game.apply({"word": word}, "You")["error"] == "already found"
    assert game.points == score_of(word, game.letters) and len(game.found) == 1


def test_bee_complete_is_queen_bee_and_cannot_shuffle_or_score_again():
    game = bee()
    for word in game.answers: game.apply({"word": word}, "You")
    state = game.state()
    assert game.over and game.won and state["rank"] == "Queen Bee" and state["rank_progress"] == 1
    assert game.points == game.total and state["answers"] == game.answers
    previous = game.others
    assert game.apply({"shuffle": True}, "You")["error"]
    assert game.others == previous and len(game.found) == len(game.answers)


@pytest.mark.parametrize("size", [64, 192, 512])
def test_bee_seven_cells_and_complete_hive_remain_inside_rendered_board(monkeypatch, size):
    import brain.games.spellingbee as module
    game = bee()
    polygons = []
    original = module.hexagon
    def capture(canvas, x, y, radius, color, *args, **kwargs):
        polygons.append((x, y, radius, color))
        return original(canvas, x, y, radius, color, *args, **kwargs)
    monkeypatch.setattr(module, "hexagon", capture)
    first = game.frame_at(size, 2)
    assert len(polygons) == 7
    for x, y, radius, _ in polygons:
        assert x - radius >= 0 and x + radius < size
        assert y - radius * 0.87 > size * 0.19 and y + radius * 0.87 < size * 0.86
    for word in game.answers: game.apply({"word": word}, "You")
    polygons.clear()
    complete = game.frame_at(size, 2)
    assert len(polygons) == 7 and np.array_equal(first[round(size * .22):round(size * .84)], complete[round(size * .22):round(size * .84)])
    assert complete.shape == (size, size, 3) and complete.dtype == np.uint8
