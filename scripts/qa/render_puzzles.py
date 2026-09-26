#!/usr/bin/env python3
"""Render production Wordle/Sudoku before and after at true panel sizes."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import types
from unittest.mock import patch

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from puzzle_fixtures import wordle, sudoku


def baseline_module(name, revision):
    source = subprocess.check_output(['git', 'show', f'{revision}:brain/games/{name}.py'], cwd=ROOT, text=True)
    # Leave the production classes/renderers intact; avoid replacing the live
    # registry while importing the prior version into this QA process.
    module = types.ModuleType(f'brain.games._baseline_{name}')
    module.__package__ = 'brain.games'
    exec(compile(source.replace('@register\n', ''), f'{revision}/brain/games/{name}.py', 'exec'), module.__dict__)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'qa/batch-09/puzzles')
    parser.add_argument('--baseline', default='8bdda75')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    before_classes = {'wordle': baseline_module('wordle', args.baseline).Wordle,
                      'sudoku': baseline_module('sudoku', args.baseline).Sudoku}
    manifest = {'baseline': args.baseline, 'sizes': [64, 192, 512], 'cases': [],
                'notes': ['All frames are actual production renderers; no screenshot mockups.',
                          'Wordle flip elapsed time is pinned for animation frames.',
                          'Pencil notes are new; the prior renderer receives the same selected-cell state but has no notes support.',
                          '64-pixel pencil notes use their 3-by-3 positions as dots; digits remain readable at192 and512.',
                          'Phone input controls sit outside the shared board composition.']}
    strips = []
    for name, builder, stages in [('wordle', wordle, ['playing', 'won', 'lost']), ('sudoku', sudoku, ['playing', 'error', 'notes', 'won'])]:
        for stage in stages:
            pair = {}
            for label in ['before', 'after']:
                game = builder(stage, cls=before_classes[name]) if label == 'before' else builder(stage)
                filenames = []
                for size in [64, 192, 512]:
                    filename = f'{name}-{stage}-{label}-{size}.png'
                    image = Image.fromarray(game.frame_at(size, 2))
                    image.save(args.output / filename)
                    filenames.append(filename)
                    if size == 192: pair[label] = image
                (args.output / f'{name}-{stage}-{label}.json').write_text(json.dumps(game.public(), indent=2) + '\n')
                manifest['cases'].append({'game': name, 'state': stage, 'version': label, 'files': filenames})
            strip = Image.new('RGB', (800, 434), (11, 10, 9))
            draw = ImageDraw.Draw(strip)
            draw.text((16, 12), f'{name.upper()} / {stage} — BEFORE', fill=(234, 228, 216))
            draw.text((416, 12), f'{name.upper()} / {stage} — AFTER', fill=(234, 228, 216))
            strip.paste(pair['before'].resize((384, 384), Image.Resampling.NEAREST), (8, 40))
            strip.paste(pair['after'].resize((384, 384), Image.Resampling.NEAREST), (408, 40))
            strip.save(args.output / f'{name}-{stage}-comparison.png')
            strips.append(strip)
    frames = []
    game = wordle('playing')
    game.revealed_at = 100
    for step in range(36):
        elapsed = step / 12
        with patch('time.monotonic', return_value=100 + elapsed):
            frames.append(Image.fromarray(game.frame_at(192, elapsed)).resize((384, 384), Image.Resampling.NEAREST))
    frames[0].save(args.output / 'wordle-reveal.gif', save_all=True, append_images=frames[1:], duration=83, loop=0, disposal=2)
    manifest['motion'] = 'wordle-reveal.gif'
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    contact = Image.new('RGB', (800, len(strips) * 434), (11, 10, 9))
    for index, strip in enumerate(strips): contact.paste(strip, (0, index * 434))
    contact.save(args.output / 'contact-sheet.png')
    print(json.dumps({'cases': len(manifest['cases']), 'native_frames': len(manifest['cases']) * 3, 'output': str(args.output)}, indent=2))


if __name__ == '__main__': main()
