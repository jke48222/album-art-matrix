"""Spelling Bee on the wall.

Seven letters in a hive, one in the middle. Make words of four letters or
more from them, always using the middle one; letters can repeat. A word
with all seven is a pangram. Four letters score one point, longer words
their length, a pangram seven more. Ranks climb with the share of the
total: Beginner, Good Start, Moving Up, Good, Solid, Nice, Great,
Amazing, Genius.

Puzzles are our own: a pangram is drawn from the common words with
exactly seven distinct letters and no s (plurals would flood it), and
its letters make the hive; the centre is the letter that keeps the most
words. The word list is the 30,000 common words, so the answers are
words a person would say. Say a word or type it; the wall lights the hive
and lists what has been found, latest first, with the rank as a bar.
Options: {"seed": n}.
"""
from __future__ import annotations

import random
import re

from . import Game, register
from .board import (BLACK, DIM, HONEY, INK, SLATE, SLATE2, WHITE, FAINT, banner, blank, ease_out, fill, header,
                    hexagon, mix, progress, text, text_centred, text_width, fit_text)
from .words import common

RANKS = [(0.0, "Beginner"), (0.02, "Good Start"), (0.05, "Moving Up"), (0.08, "Good"), (0.15, "Solid"),
         (0.25, "Nice"), (0.40, "Great"), (0.50, "Amazing"), (0.70, "Genius")]
_WORD = re.compile(r"^(?:(?:the word is|try|how about|i say|guess)\s+)?([a-z]+)[.!?]*$")


def score_of(word: str, letters: set[str]) -> int:
    n = len(word)
    s = 1 if n == 4 else n
    if set(word) == letters:
        s += 7
    return s


def rank_of(points: int, total: int) -> str:
    share = points / total if total else 0.0
    name = RANKS[0][1]
    for cut, nm in RANKS:
        if share >= cut:
            name = nm
    return name


def make_hive(rng: random.Random, words: list[str]) -> tuple[str, str, list[str]]:
    """(centre, the other six letters, all the answers)."""
    pangrams = [w for w in words if len(set(w)) == 7 and "s" not in w and len(w) >= 7]
    rng.shuffle(pangrams)
    for pan in pangrams[:60]:
        letters = set(pan)
        pool = [w for w in words if len(w) >= 4 and set(w) <= letters]
        best = None
        for centre in sorted(letters):
            answers = [w for w in pool if centre in w]
            if 20 <= len(answers) <= 90 and (best is None or len(answers) > len(best[1])):
                best = (centre, answers)
        if best:
            centre, answers = best
            others = "".join(sorted(letters - {centre}))
            return centre, others, sorted(set(answers))
    raise RuntimeError("no hive in the words")


@register
class SpellingBee(Game):
    name = "spellingbee"
    title = "Spelling Bee"
    blurb = "Seven letters, one in the middle. Say words of four or more."
    min_players = 1
    max_players = 4

    def setup(self):
        rng = random.Random(self.options.get("seed"))
        words = common(4, 12)
        if not words:
            raise RuntimeError("no word list")
        self.centre, self.others, self.answers = make_hive(rng, words)
        self.letters = set(self.centre + self.others)
        self.found: list[tuple[str, str]] = []           # (word, who)
        self.points = 0
        self.total = sum(score_of(w, self.letters) for w in self.answers)
        self.pangrams = [w for w in self.answers if set(w) == self.letters]
        self.message = f"{len(self.answers)} words, {len(self.pangrams)} pangram{'s' if len(self.pangrams) != 1 else ''}."

    def apply(self, move: dict, player: str) -> dict:
        word = str(move.get("word") or move.get("guess") or "").lower().strip()
        return self.say(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        m = _WORD.match(text.lower().strip())
        if not m:
            return None
        w = m.group(1)
        if len(w) < 4 or not set(w) <= self.letters:
            return None                              # not even made of the hive: not for us
        return self.say(w, player)

    def say(self, word: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if len(word) < 4:
            return {"error": "four letters or more"}
        if not set(word) <= self.letters:
            return {"error": "not in the hive"}
        if self.centre not in word:
            return {"error": f"needs the middle letter, {self.centre.upper()}"}
        if any(word == w for w, _ in self.found):
            return {"error": "already found"}
        if word not in self.answers:
            return {"error": "not in the list"}
        pts = score_of(word, self.letters)
        self.found.insert(0, (word, player))
        self.points += pts
        pangram = set(word) == self.letters
        self.message = ("Pangram! " if pangram else "") + f"+{pts}. {rank_of(self.points, self.total)}."
        if len(self.found) == len(self.answers):
            self.finish(won=True, message="Queen Bee. Every word.")
        else:
            self.changed()
        return {"word": word, "points": pts, "pangram": pangram, "rank": rank_of(self.points, self.total)}

    def state(self) -> dict:
        return {"centre": self.centre, "letters": self.others, "found": [{"word": w, "who": p} for w, p in self.found],
                "points": self.points, "total": self.total, "rank": rank_of(self.points, self.total),
                "count": len(self.answers), "pangrams": len(self.pangrams),
                "answers": self.answers if self.over else None}

    def voice_words(self) -> list[str]:
        return list(self.answers)

    def frame_at(self, size: int, t: float):
        import math
        c = blank(size)
        big = size > 96
        s = 3 if big else 1
        r = 19 if big else 6                        # a cell's radius
        cx = size // 2
        cy = (size // 2 - 5) if not big else 82
        step = r * 1.9
        spots = [(0, 0)] + [(round(step * math.cos(k * math.pi / 3)), round(step * math.sin(k * math.pi / 3)))
                            for k in range(6)]
        letters = [self.centre] + list(self.others)
        pop = ease_out(self.age() / 0.35) if self.age() < 0.35 else 1.0
        for (dx, dy), ch in zip(spots, letters):
            x, y = cx + dx, cy + dy
            centre = ch == self.centre
            rr = r * (0.85 + 0.15 * pop) if centre else r
            hexagon(c, x + 0.5, y + 0.5, rr, HONEY if centre else SLATE2, pointy=False)
            if big:
                hexagon(c, x + 0.5, y + 0.5, rr - 1.5, HONEY if centre else SLATE, pointy=False)
                hexagon(c, x + 0.5, y + 0.5, rr - 1.5 - 0.01, HONEY if centre else SLATE2, pointy=False)
            gw, gh = 5 * s, 7 * s
            text(c, ch.upper(), x - gw // 2 + 1, y - gh // 2 + 1, BLACK if centre else INK, s)
        share = self.points / self.total if self.total else 0.0
        rank = rank_of(self.points, self.total)
        if big:
            y = cy + int(step) + r + 8
            for word, _ in self.found[:3]:
                text_centred(c, word.upper(), cx, y, INK if word == self.found[0][0] else DIM, 1)
                y += 9
            progress(c, 8, size - 12, size - 16, 3, share, HONEY, FAINT, WHITE)
            text(c, rank, 8, size - 22, DIM, 1)
            text(c, f"{self.points} pts", size - 8 - text_width(f"{self.points} pts", 1), size - 22, INK, 1)
        else:
            if self.found:
                text_centred(c, fit_text(self.found[0][0].upper(), size - 4, 1), cx, size - 12, INK, 1)
            progress(c, 2, size - 3, size - 4, 1, share, HONEY, FAINT)
        if self.over:
            banner(c, size, self.message, BLACK, HONEY)
        header(c, size, "SPELLING BEE", f"{len(self.found)} of {len(self.answers)}" if not self.over else "", s, accent=HONEY)
        return c
