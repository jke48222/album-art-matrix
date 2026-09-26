"""Deterministic real puzzle states shared by native and renderer QA."""
from brain.games.wordle import Wordle
from brain.games.sudoku import Sudoku

PUZZLE = '530070000600195000098000060800060003400803001700020006060000280000419005000080079'


def wordle(stage='playing', cls=Wordle):
    game = cls(None, {'word': 'crane'}, ['You'])
    game.setup()
    guesses = [] if stage == 'ready' else ['slate', 'trace']
    if stage == 'won': guesses.append('crane')
    if stage == 'lost': guesses = ['slate', 'ocean', 'cramp', 'brick', 'house', 'plumb']
    for guess in guesses:
        response = game.apply({'guess': guess}, 'You')
        if response.get('error'): raise ValueError(response['error'])
    game.revealed_at = None
    return game


def sudoku(stage='playing', cls=Sudoku):
    game = cls(None, {'puzzle': PUZZLE}, ['You'])
    game.setup()
    empty = [index for index, value in enumerate(game.puzzle) if not value]
    if stage != 'ready':
        for index in empty[:2]: game.apply({'cell': index, 'digit': game.solution[index]}, 'You')
        game.apply({'choose': empty[2]}, 'You')
    if stage == 'error':
        game.apply({'cell': empty[2], 'digit': game.solution[empty[2]] % 9 + 1}, 'You')
    if stage == 'notes':
        for digit in [2, 4, 8]: game.apply({'cell': empty[2], 'note': digit}, 'You')
    if stage == 'won':
        for index in empty: game.apply({'cell': index, 'digit': game.solution[index]}, 'You')
    return game


def status(name, stage='playing'):
    game = wordle(stage) if name == 'wordle' else sudoku(stage)
    return {'running': True, 'seq': game.seq, 'game': game.public(), 'scores': {}, 'voice_words': game.voice_words()}
