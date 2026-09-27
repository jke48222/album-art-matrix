"""Mini crossword entry, immutable acknowledgements, valid fills and RGB layout."""
from copy import deepcopy
from types import SimpleNamespace

import numpy as np
import pytest

from brain.games.crossword import BUNDLED, CROSSWORD_COLOURS, Crossword, slots
from brain.games.words import common_set


def puzzle():
    game = Crossword(None, {"set": 0, "seed": 7})
    game.setup()
    return game


def play(game, move):
    return game.apply(move, "You")


def solve(game):
    for slot in list(game.slots):
        if game.over:
            break
        assert "error" not in play(game, {"slot": slot["id"], "word": "".join(game.solution[c] for c in slot["cells"])})
    assert game.over and game.won


def test_every_bundled_crossing_is_a_real_word_with_its_own_clue():
    dictionary = common_set()
    for blacks, rows, clues in BUNDLED:
        entries = slots(set(blacks))
        assert len(rows) == 5 and all(len(row) == 5 for row in rows)
        assert set(clues) == {s["id"] for s in entries}
        assert all(clues[s["id"]].strip() for s in entries)
        for slot in entries:
            answer = "".join(rows[r][c] for r, c in slot["cells"])
            assert answer in dictionary, (slot["id"], answer)


def test_authored_fill_and_clues_agree():
    game = puzzle()
    expected = {"1A": "puff", "1D": "piano", "2D": "undid", "3D": "false", "4D": "flee",
                "5A": "final", "5D": "flan", "6A": "ladle", "7A": "anise", "8A": "node"}
    assert {s["id"]: "".join(game.solution[c] for c in s["cells"]) for s in game.slots} == expected
    assert game.clues["1D"] == "Instrument with 88 keys"


@pytest.mark.parametrize("move", [
    None, [], "puff", {}, {"choose": []}, {"choose": "99A"}, {"choose": ""},
    {"slot": "", "word": "puff"}, {"slot": [], "word": "puff"}, {"word": 12},
    {"word": "püff"}, {"word": "1234"}, {"word": "puffs"},
    {"letter": "ab"}, {"letter": 3}, {"letter": None}, {"letter": "é"}, {"letter": "#"},
    {"cell": [0, 0], "letter": "a"}, {"cell": [5, 0], "letter": "a"},
    {"cell": [-1, 0], "letter": "a"}, {"cell": [1.5, 2], "letter": "a"},
    {"cell": [True, 2], "letter": "a"}, {"cell": ["1", 2], "letter": "a"},
    {"cell": [1], "letter": "a"}, {"cell": "12", "letter": "a"},
    {"select": [0, 0]}, {"select": [1, 1], "direction": "diagonal"},
    {"select": [0, 1], "direction": 4}, {"check": 1}, {"check": False},
    {"backspace": "true"}, {"clear": True}, {"clear": ""}, {"clear": "99A"},
    {"word": "puff", "unexpected": True}, {"letter": "p", "client_move_id": 5},
    {"letter": "p", "client_move_id": ""}, {"letter": "p", "client_move_id": "x" * 81},
])
def test_rejected_moves_do_not_change_any_public_state(move):
    game = puzzle()
    before = deepcopy(game.public())
    result = play(game, move)
    assert "error" in result
    assert game.public() == before


def test_repeat_cell_toggles_crossing_direction_and_arbitrary_cell_preserves_it():
    game = puzzle()
    assert game.chosen == "1A" and game.selected == (0, 1)
    play(game, {"select": [0, 1]})
    assert game.chosen == "1D"
    play(game, {"select": [2, 1]})
    assert game.chosen == "1D" and game.selected == (2, 1)
    play(game, {"select": [2, 1]})
    assert game.chosen == "6A"
    play(game, {"select": [2, 1], "direction": "down"})
    assert game.chosen == "1D"


def test_letter_entry_skips_filled_crossing_and_moves_to_next_clue():
    game = puzzle()
    play(game, {"cell": [0, 2], "letter": "u"})
    play(game, {"choose": "1A"})
    assert game.selected == (0, 1)
    play(game, {"letter": "p"})
    assert game.selected == (0, 3)
    play(game, {"letter": "f"})
    play(game, {"letter": "f"})
    assert game.chosen == "5A" and game.selected == (1, 0)
    assert game.state()["filled_slots"] == ["1A"]
    assert game.state()["remaining"] == 19


def test_backspace_clears_current_letter_then_previous_when_current_is_blank():
    game = puzzle()
    play(game, {"word": "puff"})
    play(game, {"choose": "1A"})
    play(game, {"select": [0, 3], "direction": "across"})
    play(game, {"backspace": True})
    assert (0, 3) not in game.grid and game.selected == (0, 3)
    play(game, {"backspace": True})
    assert (0, 2) not in game.grid and game.selected == (0, 2)
    play(game, {"choose": "1A"})
    play(game, {"cell": [0, 1], "letter": ""})
    play(game, {"backspace": True})
    assert game.selected == (0, 1)


def test_clear_answer_clears_shared_letters_and_wrong_markers_without_resetting_other_clues():
    game = puzzle()
    play(game, {"slot": "1A", "word": "xxxx"})
    play(game, {"slot": "5A", "word": "final"})
    play(game, {"check": True})
    assert len(game.wrong) == 4
    play(game, {"clear": "1a"})
    assert not game.wrong
    assert game.grid == {(1, c): ch for c, ch in enumerate("final")}
    assert game.chosen == "1A" and game.selected == (0, 1)
    assert game.state()["feedback"]["kind"] == "erased"


def test_check_reports_errors_without_revealing_answers_and_repair_clears_only_edited_marker():
    game = puzzle()
    play(game, {"word": "xxxx"})
    assert game.state()["solution"] is None
    assert play(game, {"check": True})["wrong"] == [[0, 1], [0, 2], [0, 3], [0, 4]]
    assert game.state()["feedback"]["kind"] == "incorrect"
    play(game, {"cell": [0, 1], "letter": "p"})
    assert (0, 1) not in game.wrong and len(game.wrong) == 3
    assert game.state()["solution"] is None


def test_full_incorrect_grid_does_not_finish():
    game = puzzle()
    for cell in game.solution:
        play(game, {"cell": list(cell), "letter": "x"})
    assert not game.over and game.state()["remaining"] == 0
    assert "Check" in game.message
    assert len(play(game, {"check": True})["wrong"]) == 23


def test_ack_is_echoed_only_after_success_and_duplicate_does_not_advance_again():
    game = puzzle()
    move = {"letter": "p", "client_move_id": "phone-entry-1"}
    play(game, move)
    assert game.state()["last_move_id"] == "phone-entry-1"
    before = deepcopy(game.public())
    assert play(game, move) == {"acknowledged": "phone-entry-1"}
    assert game.public() == before
    assert "error" in play(game, {"letter": "u", "client_move_id": "phone-entry-1"})
    assert game.public() == before
    assert "error" in play(game, {"word": "too-long", "client_move_id": "rejected"})
    assert game.state()["last_move_id"] == "phone-entry-1"


def test_ack_payload_is_not_aliased_to_the_callers_dictionary():
    game = puzzle()
    move = {"cell": [0, 1], "letter": "p", "client_move_id": "phone-entry-1"}
    play(game, move)
    move["cell"][1] = 2
    assert "error" in play(game, move)
    assert game.selected == (0, 2) and game.grid == {(0, 1): "p"}


@pytest.mark.parametrize("move", [{"choose": "1A"}, {"select": [0, 1]}, {"check": True},
                                  {"clear": "1A"}, {"backspace": True}, {"letter": "x"},
                                  {"cell": [0, 1], "letter": "x"}, {"slot": "1A", "word": "xxxx"}])
def test_completed_grid_rejects_every_mutation(move):
    game = puzzle()
    solve(game)
    before = deepcopy(game.public())
    assert "error" in play(game, move)
    assert "error" in game.hear("check", "You")
    assert "error" in game.enter("1A", "xxxx")
    assert "error" in game.check()
    assert game.public() == before
    assert game.state()["solution"][0] == ["#", "p", "u", "f", "f"]


def test_voice_accepts_clue_direction_or_selected_answer_and_rejects_wrong_length():
    game = puzzle()
    assert game.hear("one across is puff", "You")["filled"] == 4
    assert "error" in game.hear("1 down pianoes", "You")
    assert game.hear("1 down: piano", "You")["filled"] == 8
    play(game, {"choose": "5A"})
    assert game.hear("final", "You")["filled"] == 12
    assert game.hear("unrelated sentence", "You") is None
    assert "piano" in game.voice_words()


def test_partial_remote_clues_fall_back_to_a_complete_authored_puzzle(monkeypatch):
    from brain.games import crossword
    fallback = puzzle()
    monkeypatch.setattr(crossword, "PATTERNS", [BUNDLED[0][0]])
    monkeypatch.setattr(crossword, "fill_grid", lambda *args, **kwargs: dict(fallback.solution))
    host = SimpleNamespace(ctrl=SimpleNamespace(asker=SimpleNamespace(ready=True, crossword_clues=lambda words: {"puff": "Only one clue"})))
    game = Crossword(host, {"seed": 7})
    game.setup()
    assert game.clues == fallback.clues
    assert all(slot["clue"] for slot in game.state()["slots"])


@pytest.mark.parametrize("value", [True, "zero", 1.5, {}, []])
def test_set_option_is_an_integer(value):
    with pytest.raises(ValueError):
        Crossword(None, {"set": value}).setup()


@pytest.mark.parametrize("side", [64, 192, 512])
def test_full_grid_uses_the_same_geometry_and_true_white_at_every_resolution(side):
    game = puzzle()
    play(game, {"word": "puff"})
    play(game, {"choose": "1D"})
    frame = game.frame_at(side, 0)
    assert frame.shape == (side, side, 3) and frame.dtype == np.uint8
    margin = max(1, round(side * 2 / 64))
    assert np.all(frame[:margin] == CROSSWORD_COLOURS["ground"])
    assert np.all(frame[:, :margin] == CROSSWORD_COLOURS["ground"])
    non_ground = np.any(frame != CROSSWORD_COLOURS["ground"], axis=2)
    ys, xs = np.nonzero(non_ground)
    assert (xs.min(), ys.min(), xs.max(), ys.max()) == (margin, margin, side - margin - 1, side - margin - 1)
    assert np.sum(np.all(frame == (255, 255, 255), axis=2)) > 20
    assert np.any(np.all(frame == CROSSWORD_COLOURS["cursor"], axis=2))
    assert np.any(np.all(frame == CROSSWORD_COLOURS["word"], axis=2))


@pytest.mark.parametrize("side", [64, 192, 512])
def test_completed_grid_keeps_every_letter_visible_without_overlay_banner(side):
    game = puzzle()
    solve(game)
    frame = game.frame_at(side, 0)
    margin = max(1, round(side * 2 / 64))
    width = side - 2 * margin
    for cell in game.solution:
        row, col = cell
        x0, x1 = margin + round(col * width / 5), margin + round((col + 1) * width / 5)
        y0, y1 = margin + round(row * width / 5), margin + round((row + 1) * width / 5)
        assert np.any(np.all(frame[y0:y1, x0:x1] == (255, 255, 255), axis=2)), cell
    assert np.any(np.all(frame == CROSSWORD_COLOURS["solved"], axis=2))
    assert not np.any(np.all(frame == CROSSWORD_COLOURS["cursor"], axis=2))
