"""Production puzzle regressions, deterministic inputs, no wall or services."""
import random
from unittest.mock import patch

import numpy as np
import pytest

from brain.games.wordle import Wordle, mark
from brain.games.sudoku import Sudoku, solve, count_solutions, full_grid

PUZZLE = '530070000600195000098000060800060003400803001700020006060000280000419005000080079'


def sudoku():
    game = Sudoku(None, {'puzzle': PUZZLE})
    game.setup()
    return game


def wordle():
    game = Wordle(None, {'word': 'crane'})
    game.setup()
    return game


def test_solvers_reject_full_duplicate_grids_and_bad_givens():
    assert solve([1] * 81) is None
    assert count_solutions([1] * 81) == 0
    valid = full_grid(random.Random(12))
    assert solve(valid) == valid and count_solutions(valid) == 1
    valid[0] = valid[1]
    assert solve(valid) is None and count_solutions(valid) == 0
    for bad in ([0] * 80, [True] + [0] * 80, [10] + [0] * 80, [1.5] + [0] * 80):
        assert solve(bad) is None and count_solutions(bad) == 0


@pytest.mark.parametrize('digit', [True, False, 1.0, 1.9, float('nan'), float('inf'), None, '12', '²', [], {}])
def test_invalid_digits_never_change_grid_or_history(digit):
    game = sudoku()
    before = game.state()
    response = game.apply({'cell': 2, 'digit': digit}, 'You')
    assert response.get('error')
    assert game.state() == before


def test_missing_digit_does_not_erase_an_existing_entry():
    game = sudoku()
    game.apply({'cell': 2, 'digit': game.solution[2]}, 'You')
    assert game.apply({'cell': 2}, 'You').get('error')
    assert game.grid[2] == game.solution[2]
    assert game.apply({'cell': 2, 'digit': 0}, 'You')['digit'] == 0


@pytest.mark.parametrize('cell', [True, False, [True, 2], [1, False], -1, 81, '²', '999', 2.0])
def test_invalid_cells_cannot_select_or_mutate(cell):
    game = sudoku()
    assert game.apply({'choose': cell}, 'You').get('error')
    assert game.chosen is None


def test_given_selection_is_readable_but_cannot_change():
    game = sudoku()
    assert game.apply({'choose': 0}, 'You')['chosen'] == 0
    assert game.apply({'digit': 2}, 'You').get('error')
    assert game.apply({'note': 2}, 'You').get('error')
    assert game.grid[0] == 5


def test_notes_toggle_prune_and_undo_as_one_edit():
    game = sudoku()
    game.apply({'cell': 2, 'note': 4}, 'You')
    game.apply({'cell': 2, 'note': 6}, 'You')
    assert game.state()['notes'] == {'2': [4, 6]}
    game.apply({'cell': 2, 'note': 6}, 'You')
    assert game.state()['notes'] == {'2': [4]}
    game.apply({'cell': 3, 'note': 4}, 'You')
    before = game.state()['notes']
    game.apply({'cell': 2, 'digit': 4}, 'You')
    assert game.state()['notes'] == {}
    assert game.state()['filled_by_you'] == 1
    assert game.apply({'undo': True}, 'You')['undone']
    assert game.grid[2] == 0 and game.state()['notes'] == before
    assert game.state()['filled_by_you'] == 0


def test_wrong_digit_undo_restores_validation_and_remaining():
    game = sudoku()
    initial_remaining = game.state()['remaining']
    game.apply({'cell': 2, 'digit': 1}, 'You')
    assert 2 in game.wrong
    assert game.state()['remaining'] == initial_remaining
    assert game.state()['left'] == initial_remaining - 1
    game.apply({'cell': 2, 'digit': 4}, 'You')
    assert 2 not in game.wrong
    game.apply({'undo': True}, 'You')
    assert 2 in game.wrong and game.grid[2] == 1


def test_completed_game_rejects_all_moves_without_mutation():
    game = sudoku()
    for index, value in enumerate(game.solution):
        if not game.puzzle[index]:
            game.apply({'cell': index, 'digit': value}, 'You')
    assert game.over and game.won and game.state()['remaining'] == 0
    assert game.state()['can_undo'] is False
    before = game.state()
    for move in ({'choose': 2}, {'cell': 2, 'digit': 0}, {'cell': 2, 'note': 4}, {'undo': True}):
        assert game.apply(move, 'You').get('error')
        assert game.state() == before


def test_undo_is_bounded_and_selection_is_not_an_edit():
    game = sudoku()
    assert game.apply({'undo': True}, 'You').get('error')
    for index in range(130):
        game.apply({'cell': 2, 'note': 4}, 'You')
        game.apply({'choose': 3}, 'You')
    assert len(game._undo) == 100
    for _ in range(100):
        assert game.apply({'undo': True}, 'You').get('undone')
    assert game.state()['can_undo'] is False


@pytest.mark.parametrize('guess', ['éclat', '１２３４５', 'abc😀d', 'abcd', 'abcdef'])
def test_wordle_accepts_only_five_ascii_letters(guess):
    game = wordle()
    assert game.guess(guess, 'You').get('error')
    assert game.rows == []
    invalid = Wordle(None, {'word': guess})
    with pytest.raises(ValueError): invalid.setup()


def test_repeated_letter_feedback_and_best_keyboard_knowledge():
    game = Wordle(None, {'word': 'there'})
    game.setup()
    game.guess('eerie', 'You')
    assert game.rows[0][1] == 'yxyxg'
    assert game.keys['e'] == 'g'
    game.guess('speed', 'You')
    assert game.keys['e'] == 'g'
    assert mark('allee', 'nasal') == 'yyxxx'


@pytest.mark.parametrize('size', [64, 192, 512])
def test_wordle_all_six_rows_fit_and_final_row_stays_after_end(size):
    game = wordle()
    for guess in ['slate', 'ocean', 'cramp', 'brick', 'house', 'plumb']:
        assert not game.guess(guess, 'You').get('error')
    game.revealed_at = None
    x, y, cell, gap = game.board_geometry(size)
    assert 0 <= x and 0 <= y and y + 6 * cell + 5 * gap <= size
    frame = game.frame_at(size, 2)
    assert frame.shape == (size, size, 3) and frame.dtype == np.uint8
    bottom = y + 5 * (cell + gap)
    for column in range(5):
        left = x + column * (cell + gap)
        tile = frame[bottom:bottom + cell, left:left + cell]
        assert len(np.unique(tile.reshape(-1, 3), axis=0)) > 2


@pytest.mark.parametrize('size', [64, 192, 512])
def test_sudoku_last_row_is_visible_and_not_overpainted_on_completion(size):
    game = sudoku()
    for index, value in enumerate(game.solution):
        if not game.puzzle[index]: game.apply({'cell': index, 'digit': value}, 'You')
    frame = game.frame_at(size, 2)
    x, y, cell = game.board_geometry(size)
    assert x >= 0 and y >= 0 and x + 9 * cell <= size and y + 9 * cell <= size
    for column in range(9):
        bottom_cell = frame[y + 8 * cell + 1:y + 9 * cell - 1, x + column * cell + 1:x + (column + 1) * cell - 1]
        assert ((bottom_cell[..., 0] > 150) & (bottom_cell[..., 1] > 170)).any()


def test_wordle_reveal_has_a_real_settle_and_no_mutation():
    game = wordle()
    game.guess('slate', 'You')
    game.revealed_at = 100
    before = game.state()
    with patch('time.monotonic', return_value=100.05): early = game.frame_at(192, .05)
    with patch('time.monotonic', return_value=102): final = game.frame_at(192, 2)
    assert not np.array_equal(early, final)
    assert game.state() == before
