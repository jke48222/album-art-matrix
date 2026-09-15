"""Wordle on the wall.

Six guesses at a five-letter word. Say the word ("crane", or "guess
crane") or type it on the phone; the wall colours the row: green in its
place, yellow elsewhere in the word, grey not in it, with the usual rule
for repeated letters (a letter is yellow only as many times as the answer
has it spare). A guess that is not a word is refused and does not count.

At 64 the grid is six rows of 9 pixel tiles with a pixel between, the
letters the 5x7 font; at 192 everything is three times the size and a
line at the top says how many guesses are left. The answer comes from
2,400 everyday five-letter words (brain/games/words.py); an option
{"word": "crane"} sets it, {"seed": n} picks one repeatably.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import (BLACK, DIM, EDGE, GREEN, GREY, INK, YELLOW, WHITE, blank, grid_geometry,
                    header, letter_tile, scale_for, text_centred, fit_text)
from .words import answers5, valid5

ROWS, COLS = 6, 5
_WORD = re.compile(r"^(?:(?:i )?guess |try |the word is |is it |it's |it is |maybe )?([a-z]{5})[.!?]*$")


def mark(guess: str, answer: str) -> str:
    """g in place, y elsewhere, x not in the word; repeats handled."""
    out = ["x"] * COLS
    spare: dict[str, int] = {}
    for i, (g, a) in enumerate(zip(guess, answer)):
        if g == a:
            out[i] = "g"
        else:
            spare[a] = spare.get(a, 0) + 1
    for i, g in enumerate(guess):
        if out[i] == "g":
            continue
        if spare.get(g, 0) > 0:
            out[i] = "y"
            spare[g] -= 1
    return "".join(out)


@register
class Wordle(Game):
    name = "wordle"
    title = "Wordle"
    blurb = "Six guesses at a five-letter word. Say it or type it."
    min_players = 1
    max_players = 4

    def setup(self):
        word = str(self.options.get("word", "")).lower().strip()
        if word and (len(word) != 5 or not word.isalpha()):
            raise ValueError("the word must be five letters")
        if not word:
            pool = answers5()
            if not pool:
                raise RuntimeError("no word list")
            rng = random.Random(self.options.get("seed"))
            word = rng.choice(pool)
        self.answer = word
        self.rows: list[tuple[str, str]] = []
        self.keys: dict[str, str] = {}
        self.turn = 0                  # whose guess it is, among the players
        self.message = "Say a five-letter word."

    # ---- moves ---------------------------------------------------------------------------------
    def apply(self, move: dict, player: str) -> dict:
        guess = str(move.get("guess") or move.get("word") or "").lower().strip()
        return self.guess(guess, player)

    def hear(self, text: str, player: str) -> dict | None:
        m = _WORD.match(text.lower().strip())
        if not m:
            return None
        return self.guess(m.group(1), player)

    def guess(self, guess: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if len(guess) != 5 or not guess.isalpha():
            return {"error": "five letters, please"}
        if guess not in valid5() and guess != self.answer:
            self.message = f"{guess.upper()} is not a word."
            self.changed()
            return {"error": self.message, "not_a_word": guess}
        marks = mark(guess, self.answer)
        self.rows.append((guess, marks))
        rank = {"x": 0, "y": 1, "g": 2}
        for ch, mk in zip(guess, marks):
            if rank[mk] >= rank.get(self.keys.get(ch, "x"), -1) or ch not in self.keys:
                self.keys[ch] = mk if rank[mk] >= rank.get(self.keys.get(ch, "x"), 0) else self.keys[ch]
        if guess == self.answer:
            n = len(self.rows)
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=["Genius.", "Magnificent.", "Impressive.", "Splendid.", "Great.", "Phew."][n - 1])
        elif len(self.rows) >= ROWS:
            self.finish(won=False, message=f"It was {self.answer.upper()}.")
        else:
            self.turn = (self.turn + 1) % len(self.players)
            self.message = f"{ROWS - len(self.rows)} left."
            self.changed()
        return {"guess": guess, "marks": marks, "row": len(self.rows) - 1}

    def state(self) -> dict:
        return {"rows": [{"word": w, "marks": m} for w, m in self.rows], "keys": self.keys,
                "guesses_left": ROWS - len(self.rows), "turn": self.players[self.turn],
                "answer": self.answer if self.over else None}

    def voice_words(self) -> list[str]:
        return list(answers5())

    # ---- the wall --------------------------------------------------------------------------------
    def frame_at(self, size: int, t: float):
        c = blank(size)
        s = scale_for(size)
        cell, gap = 9 * s, 1 * s
        top = 2 if size <= 96 else 14
        x0, y0, cell, gap = grid_geometry(size, COLS, ROWS, cell, gap, top=top)
        colours = {"g": GREEN, "y": YELLOW, "x": GREY}
        for r in range(ROWS):
            for col in range(COLS):
                x = x0 + col * (cell + gap)
                y = y0 + r * (cell + gap)
                if r < len(self.rows):
                    word, marks = self.rows[r]
                    letter_tile(c, x, y, cell, word[col], colours[marks[col]], INK, s)
                else:
                    letter_tile(c, x, y, cell, "", None, INK, s, edge=EDGE if r == len(self.rows) and not self.over else (40, 40, 44))
        if self.over and size > 96:
            text_centred(c, fit_text(self.message, size - 8, 1), size // 2, size - 10, WHITE if self.won else DIM, 1)
        header(c, size, "Wordle", f"{ROWS - len(self.rows)} left" if not self.over else self.answer.upper(), s)
        return c
