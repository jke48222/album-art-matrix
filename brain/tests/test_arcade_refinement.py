"""Regression coverage for the stateful Snake and Tetris remote controls."""
from copy import deepcopy
from types import SimpleNamespace

import numpy as np
import pytest

from brain.games.arcade import Snake, Tetris, PIECES, COLOURS, rotated


def game(kind, **options):
    clock = [10.0]
    g = kind(None, options, ['You'])
    g._clock = lambda: clock[0]
    g.setup()
    return g, clock


def start(g):
    assert g.apply({'start': True}, 'You') == {'started': True}


def advance(g, clock, duration, step=0.025):
    target = clock[0] + duration
    while clock[0] < target - 1e-9:
        clock[0] = min(target, clock[0] + step)
        g.step()


@pytest.mark.parametrize('kind', [Snake, Tetris])
def test_ready_does_not_consume_time(kind):
    g, clock = game(kind, seed=3)
    initial = deepcopy(g.state())
    clock[0] += 120
    assert g.state() == initial
    start(g)
    assert g.phase == 'playing'
    assert g.apply({'start': True}, 'You')['error']


@pytest.mark.parametrize('kind', [Snake, Tetris])
@pytest.mark.parametrize('payload', [None, [], {}, {'start': 1}, {'again': 'yes'}, {'pause': False},
                                     {'resume': None}, {'start': True, 'dir': 'up'}, {'move': 12}, {'dir': []}])
def test_invalid_commands_leave_round_unchanged(kind, payload):
    g, clock = game(kind)
    before = deepcopy(g.state())
    assert g.apply(payload, 'You')['error']
    assert g.state() == before


@pytest.mark.parametrize('pace', [0, -1, 0.069, 0.501, float('nan'), float('inf'), True, '0.1', 10**1000])
def test_snake_validates_pace(pace):
    with pytest.raises(ValueError):
        game(Snake, step=pace)


@pytest.mark.parametrize('kind', [Snake, Tetris])
def test_pause_resume_and_clock_discontinuities(kind):
    g, clock = game(kind)
    start(g)
    advance(g, clock, 0.1)
    assert g.apply({'pause': True}, 'You')['paused']
    frozen = deepcopy(g.state())
    clock[0] += 800
    assert g.state() == frozen
    assert g.apply({'resume': True}, 'You')['resumed']
    assert g.phase == 'playing'
    clock[0] += 5
    g.step()
    assert g.phase == 'paused' and not g.over
    assert g.apply({'resume': True}, 'You')['resumed']
    clock[0] -= 1
    g.step()
    assert g.phase == 'paused' and not g.over


@pytest.mark.parametrize('kind', [Snake, Tetris])
@pytest.mark.parametrize('time', [float('nan'), float('inf'), -1, True])
def test_invalid_clock_pauses_without_destroying_board(kind, time):
    g, clock = game(kind)
    start(g)
    before = deepcopy(g.body if kind is Snake else g.well)
    clock[0] = time
    g.step()
    assert g.phase == 'paused' and not g.over
    assert (g.body if kind is Snake else g.well) == before
    assert g.apply({'resume': True}, 'You')['error']


@pytest.mark.parametrize('kind', [Snake, Tetris])
def test_wall_mode_change_preserves_round(kind):
    g, clock = game(kind)
    start(g)
    mode = {'mode': 'art'}
    g.host = SimpleNamespace(game=g, ctrl=SimpleNamespace(get=lambda: mode), changed=lambda: None)
    g.step()
    assert g.phase == 'paused'
    assert g.apply({'resume': True}, 'You')['error']
    mode['mode'] = 'game'
    assert g.apply({'resume': True}, 'You')['resumed']


def test_snake_queues_two_turns_in_order_without_reversing():
    g, clock = game(Snake, step=0.1)
    start(g)
    assert g.apply({'dir': 'left'}, 'You')['error']
    assert g.apply({'dir': 'up'}, 'You')['accepted']
    assert g.apply({'dir': 'left'}, 'You')['accepted']
    assert g.apply({'dir': 'down'}, 'You')['error']  # full queue, not lost silently
    mid = g.N // 2
    advance(g, clock, 0.1)
    assert g.body[0] == (mid, mid - 1)
    advance(g, clock, 0.1)
    assert g.body[0] == (mid - 1, mid - 1) and not g.turns
    assert g.apply({'dir': 'right'}, 'You')['error']


def test_snake_input_does_not_rewrite_the_elapsed_interval():
    g, clock = game(Snake, step=0.1)
    start(g)
    mid = g.N // 2
    clock[0] += 0.1
    g.apply({'dir': 'up'}, 'You')
    assert g.body[0] == (mid + 1, mid)
    advance(g, clock, 0.1)
    assert g.body[0] == (mid + 1, mid - 1)


def test_snake_growth_tail_and_complete_garden():
    g, clock = game(Snake, seed=3, step=0.1)
    start(g)
    g.food = (g.N // 2 + 1, g.N // 2)
    advance(g, clock, 0.1)
    assert g.score == 1 and len(g.body) == 4 and g.food not in g.body
    # A moving tail vacates its square during this step.
    g.body = [(1, 1), (1, 2), (0, 2), (0, 1)]
    g.dir = g.next_dir = (-1, 0); g.food = (5, 5)
    advance(g, clock, g.step_s)
    assert g.body[0] == (0, 1) and not g.over
    # The final free square is not an infinite random-food loop.
    g.body = [(0, 0)] + [(x, y) for y in range(g.N) for x in range(g.N) if (x, y) not in ((0, 0), (1, 0))]
    g.food = (1, 0); g.dir = g.next_dir = (1, 0)
    advance(g, clock, g.step_s)
    assert g.over and g.won and g.reason == 'filled' and g.food is None
    assert len(g.state()['body']) == g.N * g.N


def test_snake_self_collision_and_end_immutability():
    g, clock = game(Snake, step=0.1)
    start(g)
    g.body = [(1, 1), (1, 2), (2, 2), (2, 1), (3, 1)]
    g.food = (10, 10)
    advance(g, clock, 0.1)
    assert g.over and not g.won and g.reason == 'self'
    before = g.state()
    assert g.apply({'dir': 'up'}, 'You')['error']
    advance(g, clock, 2)
    assert g.state() == before
    assert g.apply({'again': True}, 'You')['again']
    assert g.phase == 'ready' and not g.over and g.finished is None


def test_snake_state_never_truncates_long_trail():
    g, _ = game(Snake)
    g.body = [(x, y) for y in range(12) for x in range(32)]
    assert len(g.state()['body']) == 384


def test_tetris_every_bag_has_all_shapes_and_continuous_preview():
    g, _ = game(Tetris, seed=19)
    values = [g.piece['kind']] + [g._next_kind() for _ in range(27)]
    assert all(set(values[i:i + 7]) == set(PIECES) for i in range(0, 28, 7))
    assert g.bag and g.state()['next']['kind'] in PIECES


@pytest.mark.parametrize('kind', list(PIECES))
def test_tetris_four_rotations_preserve_each_shape(kind):
    original = PIECES[kind]
    assert len(set(rotated(original, 1))) == 4
    assert rotated(original, 4) == original
    if kind == 'O':
        assert rotated(original, 1) == original


def test_tetris_square_never_drifts_and_floor_kick_works():
    g, _ = game(Tetris)
    start(g)
    g.piece = {'kind': 'O', 'x': 3, 'y': 17, 'r': 0}
    before = dict(g.piece)
    for _ in range(4):
        assert not g.apply({'move': 'rotate'}, 'You')['moved']
        assert g.piece == before
    g.piece = {'kind': 'T', 'x': 3, 'y': 18, 'r': 0}
    result = g.apply({'move': 'rotate'}, 'You')
    assert result['moved'] and g._fits(g.piece) and g.piece['y'] == 17


def test_tetris_ghost_drop_and_score_are_atomic():
    g, clock = game(Tetris, seed=13)
    start(g)
    g.well[19] = ['I'] * 6 + [None] * 4
    g.piece = {'kind': 'I', 'x': 6, 'y': 0, 'r': 0}
    assert g.ghost_y() == 18
    returned = g.apply({'move': 'drop'}, 'You')
    assert returned['moved'] and g.lines == 1 and g.score == 136
    assert all(cell is None for row in g.well for cell in row)
    assert g.last_fall == clock[0] and g.pieces_placed == 1
    returned['piece']['x'] = 99
    assert g.piece['x'] == 3  # response does not alias mutable production state


def test_tetris_four_lines_use_pre_clear_level():
    g, _ = game(Tetris)
    start(g)
    for y in range(16, 20):
        g.well[y] = ['J'] * 10; g.well[y][5] = None
    g.lines = 9; g.level = 1
    g.piece = {'kind': 'I', 'x': 3, 'y': 15, 'r': 1}
    g.apply({'move': 'drop'}, 'You')
    assert g.lines == 13 and g.level == 2 and g.score == 802 and g.last_clear == 4
    assert all(cell is None for row in g.well for cell in row)


def test_tetris_grounding_grace_and_soft_drop_points():
    g, clock = game(Tetris)
    start(g)
    g.piece = {'kind': 'O', 'x': 3, 'y': 17, 'r': 0}
    assert g.apply({'move': 'down'}, 'You')['moved']
    assert g.score == 1 and g.grounded_since == clock[0]
    assert not g.apply({'move': 'down'}, 'You')['moved']
    assert g.score == 1 and g.pieces_placed == 0
    advance(g, clock, 0.49)
    assert g.pieces_placed == 0
    advance(g, clock, 0.02)
    assert g.pieces_placed == 1
    assert g.piece['y'] == 0


def test_tetris_lock_reset_limit_prevents_infinite_ground_stalling():
    g, clock = game(Tetris)
    start(g)
    g.piece = {'kind': 'O', 'x': 3, 'y': 18, 'r': 0}
    g._ground(clock[0])
    for index in range(20):
        clock[0] += 0.01
        g.apply({'move': 'left' if index % 2 == 0 else 'right'}, 'You')
    assert g.lock_resets == 15
    advance(g, clock, 0.5)
    assert g.pieces_placed == 1


def test_tetris_top_out_never_discards_hidden_cells():
    g, _ = game(Tetris)
    start(g)
    g.piece = {'kind': 'I', 'x': 3, 'y': -2, 'r': 1}
    before = deepcopy(g.well)
    g._lock()
    assert g.over and g.reason == 'ceiling' and g.well == before
    final = g.state()
    assert g.apply({'move': 'drop'}, 'You')['error']
    assert g.state() == final


@pytest.mark.parametrize('kind', [Snake, Tetris])
@pytest.mark.parametrize('size', [64, 192, 512])
def test_full_board_geometry_and_readable_hud(kind, size):
    from scripts.qa.arcade_games_fixtures import build
    g = build(kind.name)
    frame = g.frame_at(size, 0)
    assert frame.shape == (size, size, 3) and frame.dtype == np.uint8
    if kind is Snake:
        assert np.any(np.all(frame == g.COLOURS['head'], axis=-1))
        assert np.any(np.all(frame == g.COLOURS['fruit'], axis=-1))
        x, y, span = [v * size for v in g.GRID]
        hx, hy = g.body[0]
        assert np.all(frame[round(y + (hy + 0.5) * span / g.N), round(x + (hx + 0.5) * span / g.N)] == g.COLOURS['head'])
    else:
        x, y, cell = [v * size for v in g.WELL]
        # The 20-row well has identical normalized size even at 512px.
        assert cell * 20 == size * 60 / 64
        cx, cy = round(x + 1.5 * cell), round(y + 19.5 * cell)
        assert tuple(frame[cy, cx]) in (COLOURS['J'], g.PALETTE['ground'])  # glyph centre at high resolution
        assert np.any(np.all(frame[:, int(size * 40 / 64):] == g.PALETTE['white'], axis=-1))


@pytest.mark.parametrize('kind', [Snake, Tetris])
def test_spoken_controls_follow_the_same_phase_rules(kind):
    g, _ = game(kind)
    assert g.hear('start!', 'You')['started']
    assert g.hear('pause.', 'You')['paused']
    assert g.hear('resume', 'You')['resumed']
    assert g.hear('the garden looks nice', 'You') is None
    assert g.hear(None, 'You') is None
