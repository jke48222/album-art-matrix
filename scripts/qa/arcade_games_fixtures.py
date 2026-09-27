"""Deterministic Snake/Tetris states rendered by an isolated production checkout."""
from __future__ import annotations
import base64
import importlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
NAMES = ('snake', 'tetris')
OPTIONS = {'snake': {'seed': 13, 'step': 0.16}, 'tetris': {'seed': 13}}
STAMP = 1790578200


def build(name, phase='playing'):
    module = importlib.import_module('brain.games.arcade')
    game = getattr(module, 'Snake' if name == 'snake' else 'Tetris')(None, OPTIONS[name], ['You'])
    game.setup()
    game._clock = lambda: 100.0
    game.last_step = game.last_fall = game.last_sample = 100.0
    if name == 'snake':
        if phase != 'ready':
            game.body = [(20, 12), (19, 12), (18, 12), (17, 12), (16, 12), (15, 12),
                         (14, 12), (13, 12), (12, 12), (12, 13), (12, 14), (12, 15),
                         (12, 16), (12, 17), (13, 17), (14, 17), (15, 17), (16, 17)]
            game.food = (23, 10)
            game.dir = game.next_dir = (1, 0)
            game.score = 15
        else:
            game.food = (21, 14)
    else:
        if phase != 'ready':
            game.well = [[None] * 10 for _ in range(20)]
            game.well[19] = ['J', 'J', 'J', None, 'O', 'O', 'L', 'L', 'L', 'L']
            game.well[18] = ['J', None, None, None, 'O', 'O', None, 'S', 'S', 'Z']
            game.well[17] = [None, None, None, None, None, None, 'S', 'S', 'Z', 'Z']
            game.well[16] = [None, None, None, None, None, None, None, None, 'Z', None]
            game.piece = {'kind': 'T', 'x': 3, 'y': 5, 'r': 0}
            game.bag = ['Z', 'I', 'J', 'S', 'O', 'L']
            game.score, game.lines, game.level = 1260, 8, 1
            if hasattr(game, 'pieces_placed'):
                game.pieces_placed = 24
        game.cleared = None
    if hasattr(game, 'phase'):
        game.phase = 'ready' if phase == 'ready' else 'paused' if phase == 'paused' else 'playing'
    if phase in ('finished', 'lost', 'won'):
        if name == 'snake':
            # The preserved final pose is the last in-bounds step at the edge.
            game.body = [(x + 11, y) for x, y in game.body]
        else:
            # A supported stack of square pieces reaches the spawn area.
            for row in range(18):
                game.well[row][4] = game.well[row][5] = 'O'
        if hasattr(game, 'phase'):
            game.phase = 'finished'
            game.reason = 'wall' if name == 'snake' else 'stack'
        game.finish(won=False, message='15 fruit collected. The trail reached the edge.' if name == 'snake'
                    else '8 lines. 1260 points. The stack reached the top.')
    else:
        game.message = {'ready': 'Start when you’re ready.', 'paused': 'Round paused. Your board is saved.'}.get(
            phase, '15 fruit collected. Keep growing.' if name == 'snake' else 'Make room for the next piece.')
    game.started, game.finished = STAMP - 120, STAMP if game.over else None
    game.changed_at = time.monotonic() - 20
    return game


def render(root, name, phase):
    sys.path.insert(0, str(Path(root).resolve()))
    game = build(name, phase)
    status = {'running': True, 'seq': 42, 'session_id': 'qa-arcade-001', 'on_wall': True,
              'game': game.public(), 'scores': {'You': {'played': 12, 'won': 3, 'streak': 0, 'best': 2}},
              'voice_words': game.voice_words()}
    from brain.games import GAMES
    frames = {str(size): base64.b64encode(game.frame_at(size, 8).tobytes()).decode() for size in (64, 192, 512)}
    return {'name': name, 'phase': phase, 'status': status, 'list': [g.describe() for g in GAMES.values()], 'frames': frames}


def data(root, name, phase):
    process = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--render', str(root), name, phase],
                             capture_output=True, text=True, timeout=30, env={**os.environ, 'PYTHONHASHSEED': '0'})
    if process.returncode:
        raise RuntimeError(process.stderr)
    return json.loads(process.stdout)


def configure(wall, name, phase, renderer_root=None):
    root = Path(renderer_root) if renderer_root else ROOT
    result = data(root, name, phase)
    wall.studies['/game'] = result['status']
    wall.studies['/game/list'] = {'games': result['list']}
    wall.capture_frame = base64.b64decode(result['frames']['64'])
    image = Image.frombytes('RGB', (512, 512), base64.b64decode(result['frames']['512']))
    buffer = io.BytesIO(); image.save(buffer, format='PNG')
    wall.covers['/game/frame.png'] = buffer.getvalue()
    wall.arcade_game_fixture = {key: value for key, value in result.items() if key != 'frames'} | {
        'renderer_root': str(root), 'options': OPTIONS[name]}


if __name__ == '__main__':
    if len(sys.argv) == 5 and sys.argv[1] == '--render':
        print(json.dumps(render(sys.argv[2], sys.argv[3], sys.argv[4])))
    else:
        raise SystemExit('Expected --render CHECKOUT snake|tetris PHASE')
