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
from .board import BLACK, blank, hexagon, progress, text_centred, text_width
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
        self._rng = rng
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
        if self.over:
            return {"error": "the game is over"}
        if move.get("shuffle") is True:
            before = self.others
            letters = list(before)
            self._rng.shuffle(letters)
            self.others = "".join(letters)
            if self.others == before:
                self.others = before[1:] + before[:1]
            self.changed()
            return {"shuffled": True}
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
        import math
        next_rank = next(((math.ceil(cut * self.total), name) for cut, name in RANKS
                          if math.ceil(cut * self.total) > self.points), (self.total, "Queen Bee"))
        prior = max((math.ceil(cut * self.total) for cut, _ in RANKS if math.ceil(cut * self.total) <= self.points), default=0)
        rank_progress = min(1.0, max(0.0, (self.points - prior) / max(1, next_rank[0] - prior)))
        return {"centre": self.centre, "letters": self.others, "found": [{"word": w, "who": p, "points": score_of(w, self.letters), "pangram": set(w) == self.letters} for w, p in self.found],
                "points": self.points, "total": self.total, "rank": "Queen Bee" if self.over and self.won else rank_of(self.points, self.total),
                "next_rank": next_rank[1], "next_points": next_rank[0], "rank_progress": 1.0 if self.over else rank_progress,
                "found_pangrams": sum(set(w) == self.letters for w, _ in self.found),
                "count": len(self.answers), "pangrams": len(self.pangrams),
                "answers": self.answers if self.over else None}

    def voice_words(self) -> list[str]:
        return list(self.answers)

    def frame_at(self, size: int, t: float):
        """A score strip, seven-letter hive and found-word receipt at every
        size. Completion brightens the same hive instead of covering it.
        """
        import math
        from .board import fill, text_right, text_scrolled
        c = blank(size)
        unit = size / 64.0
        margin = max(2, round(3 * unit))
        font = max(1, round(size / 192))
        honey, paper, cell = (232, 178, 44), (234, 228, 216), (30, 27, 22)
        state = self.state()
        # The full rank, as the phone says it. A rank wider than its box
        # travels through it, so "MOVING UP" is never cut to "UP".
        rank = "QUEEN BEE" if self.over else state["rank"].upper()
        top = max(1, round(2 * unit))
        text_scrolled(c, rank, margin, top, size - 2 * margin - text_width(str(self.points), font) - max(2, round(3 * unit)), t, honey, font, height=7)
        text_right(c, str(self.points), size - margin, top, paper, font)
        progress(c, margin, round(12 * unit), size - 2 * margin, max(1, round(unit)),
                 self.points / max(1, self.total), honey, (55, 48, 36))
        radius = size * 0.118
        cx, cy = size * 0.5, size * 0.53
        step = radius * 1.82
        spots = [(0, 0)] + [(step * math.cos(k * math.pi / 3 + math.pi / 6),
                            step * math.sin(k * math.pi / 3 + math.pi / 6)) for k in range(6)]
        glyph = max(1, round(size / 64))
        for (dx, dy), ch in zip(spots, self.centre + self.others):
            x, y = cx + dx, cy + dy
            middle = dx == dy == 0
            hexagon(c, x, y, radius, honey if middle else cell, pointy=False)
            text_centred(c, ch.upper(), round(x), round(y - 3.5 * glyph), BLACK if middle else paper, glyph)
            if middle:
                fill(c, round(x - 2 * unit), round(y + 4.5 * unit), max(2, round(4 * unit)), max(1, round(unit)), BLACK)
        latest = self.found[0][0].upper() if self.found else f"USE {self.centre.upper()}"
        if self.over:
            latest = f"{len(self.found)} FOUND"
        text_scrolled(c, latest, margin, round(size * 0.86), size - 2 * margin, t, paper, font, height=7)
        if size >= 128:
            label = "EVERY WORD FOUND" if self.over else f"{len(self.found)}/{len(self.answers)} WORDS  /  {state['found_pangrams']} PANGRAMS"
            text_centred(c, label, size // 2, size - margin - 7 * font, (150, 144, 127), font)
        return c
