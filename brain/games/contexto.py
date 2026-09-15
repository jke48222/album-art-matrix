"""Contexto on the wall.

A secret word. Guess any word and the wall tells you how close it is in
meaning: a rank, 1 being the word itself, from a local file of word
vectors (twenty thousand everyday words in fifty dimensions, cut from
GloVe, brain/games/words/vectors50.npz). Green under 300, yellow under
1500, red beyond. Say a word or type it; the wall shows the last guess's
rank in big digits with a bar for its colour, and the best rank so far.
"Give up" shows the word. Options: {"word": w}, {"seed": n}.
"""
from __future__ import annotations

import os
import random
import re
from functools import lru_cache

import numpy as np

from . import Game, register
from .board import (BLACK, DIM, GREEN, INK, RED, YELLOW, WHITE, blank, fill, header, scale_for, text,
                    text_centred, fit_text, text_width)

VECTORS = os.path.join(os.path.dirname(__file__), "words", "vectors50.npz")
_WORD = re.compile(r"^(?:(?:the word is|try|how about|maybe|is it|guess)\s+)?([a-z]+)[.!?]*$")


@lru_cache(maxsize=None)
def vectors() -> tuple[list[str], np.ndarray, dict[str, int]]:
    d = np.load(VECTORS)
    vocab = [str(w) for w in d["vocab"]]
    M = d["vectors"].astype(np.float32)
    return vocab, M, {w: i for i, w in enumerate(vocab)}


def ranking(secret: str) -> np.ndarray:
    """Every word's rank against the secret: rank[i] of vocab[i], 1 is the
    secret itself."""
    vocab, M, index = vectors()
    sims = M @ M[index[secret]]
    order = np.argsort(-sims)
    ranks = np.empty(len(vocab), dtype=np.int32)
    ranks[order] = np.arange(1, len(vocab) + 1)
    return ranks


def colour_of(rank: int):
    return GREEN if rank <= 300 else YELLOW if rank <= 1500 else RED


@register
class Contexto(Game):
    name = "contexto"
    title = "Contexto"
    blurb = "Guess the secret word by meaning. Every guess gets a rank."
    min_players = 1
    max_players = 4

    def setup(self):
        vocab, M, index = vectors()
        word = str(self.options.get("word", "")).lower().strip()
        if word and word not in index:
            raise ValueError("that word is not in the list")
        if not word:
            rng = random.Random(self.options.get("seed"))
            pool = [w for w in vocab[300:6000] if len(w) >= 4 and w.isalpha()]
            word = rng.choice(pool)
        self.secret = word
        self.ranks = ranking(word)
        self.guesses: list[tuple[str, int, str]] = []          # (word, rank, who), best first
        self.latest: tuple[str, int, str] | None = None
        self.best: int | None = None
        self.gave_up = False
        self.message = "Say a word."

    def apply(self, move: dict, player: str) -> dict:
        if move.get("give_up") or move.get("word") == "give up":
            return self.give_up()
        word = str(move.get("word") or move.get("guess") or "").lower().strip()
        return self.guess(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        t = text.lower().strip()
        if t in ("give up", "i give up", "reveal", "tell me"):
            return self.give_up()
        m = _WORD.match(t)
        if not m:
            return None
        w = m.group(1)
        vocab, M, index = vectors()
        if w not in index:
            return None
        return self.guess(w, player)

    def guess(self, word: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        vocab, M, index = vectors()
        if not word or not word.isalpha():
            return {"error": "one word"}
        if word not in index:
            return {"error": f"{word} is not in the list"}
        if any(g[0] == word for g in self.guesses):
            r = next(g[1] for g in self.guesses if g[0] == word)
            return {"word": word, "rank": r, "again": True}
        rank = int(self.ranks[index[word]])
        self.latest = (word, rank, player)
        self.guesses.append(self.latest)
        self.guesses.sort(key=lambda g: g[1])
        self.best = rank if self.best is None else min(self.best, rank)
        if rank == 1:
            n = len(self.guesses)
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"{word.upper()} in {n}.")
        else:
            self.message = f"{word}: {rank}."
            self.changed()
        return {"word": word, "rank": rank, "best": self.best, "guesses": len(self.guesses)}

    def give_up(self) -> dict:
        if self.over:
            return {"error": "the game is over"}
        self.gave_up = True
        self.finish(won=False, message=f"It was {self.secret.upper()}.")
        return {"secret": self.secret}

    def state(self) -> dict:
        return {"guesses": [{"word": w, "rank": r, "who": p} for w, r, p in self.guesses],
                "best": self.best, "count": len(self.guesses),
                "last": {"word": self.latest[0], "rank": self.latest[1]} if self.latest else None,
                "secret": self.secret if self.over else None}

    def voice_words(self) -> list[str]:
        vocab, M, index = vectors()
        return vocab[:3000]

    def frame_at(self, size: int, t: float):
        c = blank(size)
        s = scale_for(size)
        if self.over:
            text_centred(c, fit_text(self.secret.upper(), size - 4, s), size // 2, size // 2 - 8 * s, INK, s)
            text_centred(c, "found" if self.won else "given up", size // 2, size // 2 + 2 * s, DIM, s)
        elif not self.guesses:
            text_centred(c, "say a", size // 2, size // 2 - 8 * s, DIM, s)
            text_centred(c, "word", size // 2, size // 2, INK, s)
        else:
            w, r, _ = self.latest
            big = 3 * s if len(str(r)) <= 3 else 2 * s
            text_centred(c, str(r), size // 2, size // 2 - 5 * big, colour_of(r), big)
            text_centred(c, fit_text(w.upper(), size - 4, s), size // 2, size // 2 + 3 * s, INK, s)
            # the bar: how close, on a log scale from 20000 to 1
            frac = 1.0 - min(1.0, max(0.0, np.log10(max(1, r)) / np.log10(20000)))
            fill(c, 2 * s, size - 3 * s, size - 4 * s, s, (40, 40, 44))
            fill(c, 2 * s, size - 3 * s, int((size - 4 * s) * frac), s, colour_of(r))
            if self.best is not None and size > 96:
                text(c, f"best {self.best}", 6, size - 16, DIM, 1)
        header(c, size, "Contexto", f"{len(self.guesses)} guesses", s)
        return c
