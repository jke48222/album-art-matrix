"""Batch 10 regressions against actual game rules, generation and LED frames."""
from copy import deepcopy
from types import SimpleNamespace
from unittest.mock import Mock
import random

import numpy as np
import pytest

from brain.games.letterboxed import LetterBoxed
from brain.games.strands import BUNDLED, COLS, ROWS, Strands, build, spangram_ok

EXTRAS = ['need', 'never', 'please', 'even', 'ever', 'else', 'real', 'seen', 'live']


def boxed():
    game = LetterBoxed(None, {'seed': 23}); game.setup()
    return game


def strands(set_number=0, seed=23):
    game = Strands(None, {'set': set_number, 'seed': seed}); game.setup()
    return game


def snapshot(game):
    return deepcopy(game.public())


def test_letterboxed_seed_produces_solvable_chain_and_stable_layout():
    game, again = boxed(), boxed()
    assert game.sides == again.sides == ['eis', 'adt', 'npr', 'clu']
    assert game.par == again.par == ('ritual', 'landscape')
    for word in game.par:
        assert not game.apply({'word': word}, 'You').get('error')
    assert game.won and game.over and len(game.used) == 12
    assert game.state()['solution'] == ['ritual', 'landscape']


@pytest.mark.parametrize('move', [None, [], {'word': True}, {'word': 13}, {'word': []}, {'word': 'ritúal'}, {'word': 'r' * 100}, {'word': 'eis'}, {'hint': 'yes'}, {'undo': False}])
def test_letterboxed_invalid_moves_leave_every_state_field_unchanged(move):
    game = boxed(); before = snapshot(game)
    assert game.apply(move, 'You').get('error')
    assert snapshot(game) == before


def test_letterboxed_undo_restores_all_letters_and_start_constraint():
    game = boxed()
    game.apply({'word': 'ritual'}, 'You')
    assert game.state()['next_letter'] == 'l'
    assert game.apply({'word': 'ritual'}, 'You').get('error')
    assert game.apply({'undo': True}, 'You') == {'undone': True}
    assert game.used == set() and game.words == []
    assert game.state()['next_letter'] is None and not game.state()['can_undo']
    assert not game.apply({'word': 'ritual'}, 'You').get('error')


def test_letterboxed_nudge_is_legal_minimal_and_idempotent():
    game = boxed()
    assert game.hint() == {'hint': 'ri'}
    before = snapshot(game)
    assert game.hint() == {'hint': 'ri'} and snapshot(game) == before
    game.apply({'word': 'ritual'}, 'You')
    assert game.hinted is None
    assert game.hint() == {'hint': 'la'}
    assert game.state()['solution'] is None
    game.undo()
    assert game.hinted is None


def test_letterboxed_finished_round_cannot_be_mutated_by_any_route():
    game = boxed()
    for word in game.par: game.play(word, 'You')
    before = snapshot(game)
    for move in ({'undo': True}, {'hint': True}, {'word': 'ritual'}):
        assert game.apply(move, 'You').get('error')
    assert game.hear('undo', 'You').get('error')
    assert game.hear('hint', 'You').get('error')
    assert snapshot(game) == before


@pytest.mark.parametrize('number', range(len(BUNDLED)))
def test_every_bundled_strands_puzzle_tiles_the_grid_and_is_reproducible(number):
    game, again = strands(number), strands(number)
    assert game.grid == again.grid and game.paths == again.paths
    flat = [cell for path in game.paths for cell in path]
    assert len(flat) == len(set(flat)) == ROWS * COLS
    assert spangram_ok(game.paths[0])
    for word, path in zip([game.spangram] + game.words, game.paths):
        assert Strands.valid_trace(path)
        assert ''.join(game.grid[r][c] for r, c in path) == word


def test_seeded_generation_never_calls_remote_content_service():
    asker = SimpleNamespace(ready=True, strands_set=Mock(side_effect=AssertionError('nondeterministic network')))
    host = SimpleNamespace(ctrl=SimpleNamespace(asker=asker))
    game = Strands(host, {'seed': 23}); game.setup()
    assert not asker.strands_set.called


@pytest.mark.parametrize('number', [True, 1.0, '0', -1, 6, [], {}])
def test_invalid_strands_set_options_fail_explicitly(number):
    with pytest.raises(ValueError): strands(number)


@pytest.mark.parametrize('bundle', [('Theme', 'span', ['a'] * 44), ('', 'recordplayer', BUNDLED[0][2]), ('Theme', 'recordplayer', ['nèedle'] + BUNDLED[0][2][1:]), ('Theme', 'recordplayer', None), ('Theme', 'recordplayer', ['needle', 'needle', 'sleeve', 'groove', 'spindle', 'stylus'])])
def test_malformed_generated_content_cannot_enter_the_grid(bundle):
    assert build(*bundle, random.Random(23)) is None


@pytest.mark.parametrize('path', [None, [], [[0, 0]] * 4, [[0, 0], [0, 1], [0, 2], [8, 3]], [[0, 0], [0, 1], [0, 2], [0, 6]], [[False, 0], [0, 1], [0, 2], [0, 3]], [[0.0, 0], [0, 1], [0, 2], [0, 3]], [[0, 0], [2, 1], [0, 2], [0, 3]], ['0', '1', '2', '3']])
def test_strands_rejects_invalid_paths_without_changing_state(path):
    game = strands(); before = snapshot(game)
    assert game.apply({'path': path}, 'You').get('error')
    assert snapshot(game) == before


def test_strands_path_submission_checks_spelling_and_preserves_path():
    game = strands(); path = game.path_of('needle'); before = snapshot(game)
    assert game.apply({'word': 'vinyl', 'path': path}, 'You').get('error')
    assert snapshot(game) == before
    assert game.apply({'word': 'needle', 'path': path}, 'You')['path'] == path
    assert game.state()['found'][0]['path'] == path
    before = snapshot(game)
    assert game.apply({'word': 'needle', 'path': path}, 'You').get('error')
    assert snapshot(game) == before


@pytest.mark.parametrize('move', [None, [], {'word': True}, {'word': 13}, {'word': 'nèedle'}, {'word': 'n' * 100}, {'hint': 'yes'}, {'hint': False}])
def test_strands_invalid_words_and_hint_flags_never_mutate(move):
    game = strands(); before = snapshot(game)
    assert game.apply(move, 'You').get('error')
    assert snapshot(game) == before


def test_strands_hints_charge_once_per_reveal_stage_and_report_credit():
    game = strands()
    assert game.hint().get('error')
    for word in EXTRAS[:3]: assert game.say(word, 'You')['theme_word'] is False
    assert game.state()['hints_available'] == 1
    assert game.hint()['ordered'] is False
    assert game.state()['hint'] == game.path_of('needle')
    before = snapshot(game)
    assert game.hint().get('error') and snapshot(game) == before
    for word in EXTRAS[3:6]: game.say(word, 'You')
    assert game.hint()['ordered'] is True
    for word in EXTRAS[6:9]: game.say(word, 'You')
    before = snapshot(game)
    assert game.hint().get('error') and snapshot(game) == before
    assert game.state()['hints_available'] == 1
    game.say('needle', 'You')
    assert game.hinted is None and not game.hint_ordered
    assert game.hint()['hint'] == game.path_of('vinyl')
    assert game.state()['hints_available'] == 0


def test_strands_duplicate_extra_does_not_earn_credit():
    game = strands(); game.say('need', 'You'); before = snapshot(game)
    assert game.say('need', 'You').get('error')
    assert snapshot(game) == before and game.state()['hint_progress'] == 1


def test_strands_final_spangram_does_not_spend_hint_credit():
    game = strands()
    for word in game.words: game.say(word, 'You')
    for word in EXTRAS[:3]: game.say(word, 'You')
    before = snapshot(game)
    assert game.hint().get('error') and snapshot(game) == before
    game.say(game.spangram, 'You')
    assert game.over and game.won and game.state()['left'] == 0
    before = snapshot(game)
    for move in ({'hint': True}, {'word': 'need'}, {'path': game.path_of('needle')}):
        assert game.apply(move, 'You').get('error')
    assert snapshot(game) == before


@pytest.mark.parametrize('size', [64, 192, 512])
def test_letterboxed_all_twelve_glyphs_are_inside_artwork_at_every_resolution(size):
    game = boxed(); frame = game.frame_at(size, 0)
    assert frame.dtype == np.uint8 and frame.shape == (size, size, 3)
    for x, y in game._spots(size).values():
        radius = max(4, int(size * .065))
        assert x - radius >= 0 and y - radius >= 0 and x + radius < size and y + radius < size
        assert np.any(frame[int(y)-radius:int(y)+radius+1, int(x)-radius:int(x)+radius+1] == 250)
    game.play('ritual', 'You')
    assert not np.array_equal(frame, game.frame_at(size, 0))


@pytest.mark.parametrize('size', [64, 192, 512])
def test_strands_bottom_row_and_found_paths_survive_at_every_resolution(size):
    game = strands(); frame = game.frame_at(size, 0)
    x0, y0, step = game.geometry(size)
    assert frame.dtype == np.uint8 and frame.shape == (size, size, 3)
    for row in range(8):
        for col in range(6):
            x, y = round(x0 + col * step), round(y0 + row * step)
            radius = max(4, int(size * .05))
            assert np.any(frame[max(0,y-radius):min(size,y+radius+1), max(0,x-radius):min(size,x+radius+1)] == 250)
    game.say('needle', 'You')
    assert not np.array_equal(frame, game.frame_at(size, 0))
    for word in [game.spangram] + game.words:
        if word not in game.found: game.say(word, 'You')
    final = game.frame_at(size, 0)
    # Completion must preserve all letter rows, rather than obscure them with a banner.
    assert np.count_nonzero(np.any(final[-max(6, round(size * .13)):], axis=2)) > size


def assert_bright_glyph(frame, glyph, x, y, colour):
    """Every intended 5×7 LED stays bright, and counters stay distinctly dark."""
    from brain.art.pixelfont import FONT
    mask = np.array([[bool(row & (1 << (4 - col))) for col in range(5)] for row in FONT[glyph.upper()]])
    cell = frame[y:y + 7, x:x + 5]
    assert cell.shape == (7, 5, 3), 'the glyph was clipped by the panel edge'
    assert np.all(cell[mask] == colour), 'a later node/marker erased part of a letter'
    assert np.all(cell[~mask].max(axis=1) < 90), 'a path filled a letter counter'
    assert np.min(cell[mask].mean(axis=1)) > 150


def test_letterboxed_true64_used_letters_retain_every_font_pixel_and_clear_counters():
    game = boxed()
    for word in game.par: game.play(word, 'You')
    frame = game.frame_at(64, 0)
    for letter, (x, y) in game._spots(64).items():
        assert_bright_glyph(frame, letter, round(x - 2.5), round(y - 3.5), (223, 185, 101))


def test_strands_true64_found_letters_do_not_overlap_the_next_row():
    game = strands()
    for word in [game.spangram] + game.words: game.say(word, 'You')
    frame = game.frame_at(64, 0)
    x0, y0, step = game.geometry(64)
    span_cells = set(tuple(cell) for cell in game.path_of(game.spangram))
    for r in range(8):
        for c in range(6):
            colour = (223, 185, 101) if (r, c) in span_cells else (144, 196, 215)
            assert_bright_glyph(frame, game.grid[r][c], int(x0 + c * step) - 2, int(y0 + r * step) - 3, colour)


@pytest.mark.parametrize('size', [192, 512])
def test_strands_large_found_discs_contain_whole_glyph_rectangles(size):
    from brain.art.pixelfont import FONT
    game = strands()
    for word in [game.spangram] + game.words: game.say(word, 'You')
    frame = game.frame_at(size, 0)
    x0, y0, step = game.geometry(size)
    scale = max(1, int(size * .083 / 7))
    span_cells = set(tuple(cell) for cell in game.path_of(game.spangram))
    for r in range(8):
        for c in range(6):
            mask = np.array([[bool(row & (1 << (4 - col))) for col in range(5)] for row in FONT[game.grid[r][c].upper()]])
            mask = np.repeat(np.repeat(mask, scale, axis=0), scale, axis=1)
            x, y = round(x0 + c * step - 2.5 * scale), round(y0 + r * step - 3.5 * scale)
            cell = frame[y:y + 7 * scale, x:x + 5 * scale]
            colour = (223, 185, 101) if (r, c) in span_cells else (144, 196, 215)
            assert np.all(cell[mask] == (13, 21, 25))
            assert np.all(cell[~mask] == colour), 'a font corner escaped the coloured disc'
