"""Real picture games: image fidelity, input safety, deadlines and state contracts."""
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace
import random

import numpy as np
import pytest
from PIL import Image

from brain.games.pictures import Sliding, Reveal, _fold, pick_sleeve


@pytest.fixture
def sleeve(tmp_path):
    # Fine detail reveals any accidental 64px master being enlarged for phones.
    y, x = np.mgrid[:600, :600]
    pixels = np.stack(((x * 13) % 256, (y * 17) % 256, ((x // 3 + y // 3) % 2) * 255), axis=-1).astype(np.uint8)
    path = tmp_path / 'authored-detail.png'; Image.fromarray(pixels).save(path)
    return str(path)


def sliding(sleeve, **options):
    game = Sliding(None, {'image': sleeve, 'seed': 23, **options}); game.setup()
    return game


def reveal(sleeve, **options):
    game = Reveal(None, {'image': sleeve, 'seed': 23, 'album': 'Blonde', 'artist': 'Frank Ocean', 'title': 'Nights', **options}, ['You', 'Sam'])
    game.setup(); game.t0 = 100.0
    clock = [100.0]; game._clock = lambda: clock[0]
    return game, clock


def test_master_retains_phone_detail_even_on_a64_pixel_wall(sleeve):
    host = SimpleNamespace(ctrl=SimpleNamespace(wall=SimpleNamespace(width=64)))
    image, _ = pick_sleeve(host, random.Random(23), 64, {'image': sleeve})
    assert image.size == (512, 512)
    lossy = image.resize((64, 64)).resize((512, 512))
    assert np.abs(np.asarray(image).astype(int) - np.asarray(lossy).astype(int)).mean() > 20


@pytest.mark.parametrize('grid', [3, 4])
def test_seeded_scramble_is_valid_and_reversible_by_undo(sleeve, grid):
    game = sliding(sleeve, grid=grid); again = sliding(sleeve, grid=grid)
    assert game.tiles == again.tiles and game.tiles != list(range(grid * grid))
    assert sorted(game.tiles) == list(range(grid * grid))
    before = game.tiles.copy(), game.gap
    game.apply({'tile': game._moves()[0]}, 'You')
    assert game.state()['can_undo'] and game.moves == 1
    assert game.apply({'undo': True}, 'You')['undone']
    assert (game.tiles, game.gap) == before and game.moves == 2 and game.undos == 1
    assert not game.state()['can_undo']


@pytest.mark.parametrize('value', [True, 3.0, '3', 2, 5, None, [], {}])
def test_invalid_grids_are_rejected(sleeve, value):
    with pytest.raises(ValueError): sliding(sleeve, grid=value)


@pytest.mark.parametrize('move', [None, [], {'tile': True}, {'tile': False}, {'tile': 1.0}, {'tile': float('inf')}, {'tile': '1'}, {'tile': -1}, {'tile': 9}, {'numbers': 1}, {'numbers': 'yes'}, {'undo': False}, {'dir': []}])
def test_sliding_invalid_moves_leave_board_history_and_settings_unchanged(sleeve, move):
    game = sliding(sleeve); before = deepcopy(game.public())
    assert game.apply(move, 'You').get('error')
    assert game.public() == before and game.history == []


def test_sliding_only_adjacent_tiles_can_move_and_completed_game_is_immutable(sleeve):
    game = sliding(sleeve)
    for tile in range(9):
        if tile not in game._moves(): assert game.apply({'tile': tile}, 'You').get('error')
    game.tiles = [0, 1, 2, 3, 4, 5, 6, 8, 7]; game.gap = 7
    assert game.apply({'tile': 8}, 'You')['moves'] == 1
    before = deepcopy(game.public())
    for move in ({'tile': 7}, {'numbers': False}, {'undo': True}): assert game.apply(move, 'You').get('error')
    assert game.public() == before and game.over and game.won


def test_sliding_numbers_are_reported_and_undo_history_is_bounded(sleeve):
    game = sliding(sleeve)
    assert game.state()['numbers']
    game.apply({'numbers': False}, 'You')
    assert not game.state()['numbers']
    for _ in range(240):
        result = game.apply({'tile': game._moves()[0]}, 'You')
        assert not result.get('error')
    assert len(game.history) == 200


@pytest.mark.parametrize('size', [64, 192, 512])
@pytest.mark.parametrize('grid', [3, 4])
def test_solved_sliding_returns_every_source_pixel_without_gaps_or_flash(sleeve, size, grid):
    game = sliding(sleeve, grid=grid)
    game.tiles = list(range(grid * grid)); game.gap = grid * grid - 1
    game.finish(won=True)
    frame = game.frame_at(size, 0)
    expected = np.asarray(game.sleeve.resize((size, size), Image.Resampling.LANCZOS))
    assert np.array_equal(frame, expected)
    assert frame.shape == (size, size, 3) and frame.dtype == np.uint8


@pytest.mark.parametrize('seconds', [0, -1, 301, float('nan'), float('inf'), True, '30', None])
def test_reveal_duration_must_be_finite_and_bounded(sleeve, seconds):
    with pytest.raises(ValueError): reveal(sleeve, seconds=seconds)


@pytest.mark.parametrize('value', [None, [], True, 13, {}, '', '...', 'x' * 121])
def test_reveal_invalid_guesses_never_enter_history(sleeve, value):
    game, _ = reveal(sleeve); before = deepcopy(game.public())
    assert game.apply({'guess': value}, 'You').get('error')
    assert game.public() == before and game.guesses == []


@pytest.mark.parametrize('guess', ['Ocean', 'Blond', 'not Frank Ocean', 'I dislike Blonde', 'Midnights', 'Frank'])
def test_reveal_rejects_substrings_and_sentences_containing_answer(sleeve, guess):
    game, _ = reveal(sleeve)
    assert game.guess(guess, 'Sam')['hit'] is False
    assert not game.over


@pytest.mark.parametrize('guess', ['FRANK OCEAN', '  Blonde  ', 'Nights', 'The Frank Ocean'])
def test_reveal_accepts_complete_normalized_names_and_freezes_win_time(sleeve, guess):
    game, clock = reveal(sleeve); clock[0] = 112.5
    assert game.guess(guess, 'Sam') == {'hit': True, 'seconds': 12.5}
    before = deepcopy(game.public()); clock[0] = 170
    assert game.public() == before
    assert game.won and game.winner == 'Sam' and game.elapsed() == 12.5
    assert game.state()['frame_step'] == 20


@pytest.mark.parametrize('offset', [30, 30.001, 80])
def test_deadline_rejects_late_wins_without_needing_a_render_first(sleeve, offset):
    game, clock = reveal(sleeve); clock[0] += offset
    assert game.guess('Blonde', 'You').get('error')
    state = game.public()
    assert state['over'] and not state['won'] and state['answer']['album'] == 'Blonde'
    assert state['elapsed'] == 30 and state['remaining'] == 0 and game.guesses == []
    clock[0] += 20
    assert game.public() == state


def test_first_deadline_public_snapshot_has_consistent_flags_and_answer(sleeve):
    game, clock = reveal(sleeve); clock[0] = 130
    state = game.public()
    assert state['over'] and not state['won'] and state['answer'] is not None


def test_duplicate_guess_does_not_erase_draft_by_acknowledging_new_history(sleeve):
    game, _ = reveal(sleeve); game.guess('Channel Orange', 'You')
    before = deepcopy(game.public())
    assert game.guess('channel orange', 'You').get('error')
    assert game.public() == before
    assert game.guess('channel orange', 'Sam')['hit'] is False
    assert game.state()['guess_count'] == 2


def test_reveal_history_and_render_cache_are_bounded(sleeve):
    game, clock = reveal(sleeve)
    for i in range(100): game.guess(f'unknown album {i}', 'You')
    assert len(game.guesses) == 80 and len(game.state()['guesses']) == 12 and game.guess_count == 100
    for size in (64, 192, 512):
        for step in range(20):
            clock[0] = 100 + step * 1.5
            frame = game.frame_at(size, 0)
            assert frame.shape == (size, size, 3)
    assert len(game.blurred) <= 9


@pytest.mark.parametrize('size', [64, 192, 512])
def test_reveal_final_image_has_no_banner_or_covering_timer(sleeve, size):
    game, clock = reveal(sleeve); clock[0] = 130
    actual = game.frame_at(size, 0)
    expected = np.asarray(game.sleeve.resize((size, size), Image.Resampling.LANCZOS))
    assert np.array_equal(actual, expected)


def test_answer_normalization_preserves_non_latin_and_removes_accents():
    assert _fold('Björk') == _fold('bjork') == 'bjork'
    assert _fold("Don't Stop") == _fold('Dont Stop')
    assert _fold('밤편지') and _fold('밤편지') != _fold('밤')
    assert _fold(None) == '' and _fold(34) == ''


@pytest.mark.parametrize('size', [64, 192, 512])
@pytest.mark.parametrize('grid', [3, 4])
def test_unsolved_tile_centres_are_from_correct_source_blocks(sleeve, size, grid):
    game = sliding(sleeve, grid=grid)
    game.apply({'numbers': False}, 'You')
    frame = game.frame_at(size, 0)
    source = game.sleeve.resize((size, size), Image.Resampling.LANCZOS)
    edges = [round(i * size / grid) for i in range(grid + 1)]
    for pos, tile in enumerate(game.tiles):
        if pos == game.gap: continue
        r, c = divmod(pos, grid); tr, tc = divmod(tile, grid)
        width, height = edges[c + 1] - edges[c], edges[r + 1] - edges[r]
        block = source.crop((edges[tc], edges[tr], edges[tc + 1], edges[tr + 1]))
        if block.size != (width, height): block = block.resize((width, height), Image.Resampling.LANCZOS)
        expected = np.asarray(block)[height // 2, width // 2]
        assert np.array_equal(frame[edges[r] + height // 2, edges[c] + width // 2], expected)
