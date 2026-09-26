"""Wordle on the wall.

Six guesses at a five-letter word. Say the word ("crane", or "guess
crane") or type it on the phone; the wall colours the row: green in its
place, yellow elsewhere in the word, grey not in it, with the usual rule
for repeated letters (a letter is yellow only as many times as the answer
has it spare). A guess that is not a word is refused and does not count.

The centered grid keeps all six rows visible at 64, 192 and 512.
Letters use the native pixel font; filled tiles add a line, two dots or
a dash so their meanings remain distinct without colour. The answer comes from
2,400 everyday five-letter words (brain/games/words.py); an option
{"word": "crane"} sets it, {"seed": n} picks one repeatably.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import (GREEN, INK, YELLOW, blank, breathe, ease_in_out,
                    letter_tile, mix, outline, tile)
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
        if word and re.fullmatch(r"[a-z]{5}", word) is None:
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
        self.revealed_at = None        # when the last row landed, for the flip

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
        guess = str(guess or "").lower().strip()
        if re.fullmatch(r"[a-z]{5}", guess) is None:
            return {"error": "five letters, please"}
        if guess not in valid5() and guess != self.answer:
            self.message = f"{guess.upper()} is not a word."
            self.changed()
            return {"error": self.message, "not_a_word": guess}
        marks = mark(guess, self.answer)
        self.rows.append((guess, marks))
        import time as _time
        self.revealed_at = _time.monotonic()
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
    FLIP_STEP, FLIP_S = 0.14, 0.42

    @staticmethod
    def board_geometry(size: int) -> tuple[int, int, int, int]:
        """A centered 5 by 6 board, including its final row at every size."""
        cell = max(1, round(size * 9 / 64))
        gap = max(1, round(size / 64))
        while ROWS * cell + (ROWS - 1) * gap > size - 2:
            cell -= 1
        return ((size - (COLS * cell + (COLS - 1) * gap)) // 2,
                (size - (ROWS * cell + (ROWS - 1) * gap)) // 2, cell, gap)

    def frame_at(self, size: int, t: float):
        import time as _time
        from .board import fill, text
        c = blank(size)
        c[:] = (11, 10, 9)
        x0, y0, cell, gap = self.board_geometry(size)
        scale = max(1, (cell - max(2, size // 64 * 2)) // 7)
        colours = {"g": GREEN, "y": YELLOW, "x": (46, 45, 43)}
        ink_dark = (10, 20, 12)
        since = max(0.0, _time.monotonic() - self.revealed_at) if self.revealed_at else 99.0
        cursor = mix((99, 112, 99), (191, 212, 183), 0.2 * breathe(t))
        for row in range(ROWS):
            for column in range(COLS):
                x = x0 + column * (cell + gap)
                y = y0 + row * (cell + gap)
                active = row == len(self.rows) and not self.over
                if row < len(self.rows):
                    word, marks = self.rows[row]
                    mark_ = marks[column]
                    back = colours[mark_]
                    ink = ink_dark if mark_ in ("g", "y") else INK
                    if row == len(self.rows) - 1 and since < self.FLIP_STEP * COLS + self.FLIP_S:
                        phase = (since - column * self.FLIP_STEP) / self.FLIP_S
                        if phase < 0:
                            letter_tile(c, x, y, cell, word[column], (26, 28, 25), INK, scale)
                            continue
                        if phase < 1:
                            squeeze = ease_in_out(abs(phase * 2 - 1))
                            height = max(1, int(cell * squeeze))
                            top = y + (cell - height) // 2
                            tile(c, x, top, cell, height, (26, 28, 25) if phase < .5 else back, scale)
                            if height >= 7 * scale:
                                text(c, word[column].upper(), x + (cell - 5 * scale) // 2,
                                     top + (height - 7 * scale) // 2, INK if phase < .5 else ink, scale)
                            continue
                    letter_tile(c, x, y, cell, word[column], back, ink, scale)
                    # Position has a solid underline; elsewhere has two dots;
                    # absent has a short dash. Colour is never the only clue.
                    baseline = y + cell - max(1, size // 128)
                    width = max(1, cell // 7)
                    if mark_ == "g":
                        fill(c, x + cell // 4, baseline, cell // 2, 1, ink)
                    elif mark_ == "y":
                        fill(c, x + cell // 3, baseline, width, 1, ink)
                        fill(c, x + 2 * cell // 3, baseline, width, 1, ink)
                    else:
                        fill(c, x + cell // 2 - width, baseline, width * 2, 1, INK)
                else:
                    letter_tile(c, x, y, cell, "", (26, 28, 25) if active else (22, 21, 19), INK, scale)
                    outline(c, x, y, cell, cell, cursor if active else (59, 57, 51),
                            max(1, size // 128), max(1, size // 192))
        # The solved board remains intact. A quiet perimeter is the ending,
        # with the answer and next action readable outside it on the phone.
        if self.over:
            colour = (163, 207, 155) if self.won else (218, 180, 103)
            fill(c, x0, max(0, y0 - max(1, gap)), COLS * cell + (COLS - 1) * gap, max(1, size // 192), colour)
        return c
