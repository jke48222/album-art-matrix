"""A local semantic search, with one proximity dial on phone and wall."""
from __future__ import annotations

import math
import os
import random
import re
from functools import lru_cache

import numpy as np

from . import Game, register
from .board import blank, fill, line, text, text_centred, text_scrolled, text_width

VECTORS = os.path.join(os.path.dirname(__file__), "words", "vectors50.npz")
_WORD = re.compile(r"^(?:(?:the word is|try|how about|maybe|is it|guess)\s+)?([a-z]{1,32})[.!?]*$")
GROUND = (11, 10, 9)
PAPER = (240, 231, 211)
MUTED = (150, 144, 127)
TRACK = (47, 44, 38)
CLOSE = (145, 191, 151)
NEAR = (223, 185, 101)
FAR = (213, 80, 67)


@lru_cache(maxsize=1)
def vectors() -> tuple[list[str], np.ndarray, dict[str, int]]:
    with np.load(VECTORS, allow_pickle=False) as data:
        vocab = [str(w) for w in data["vocab"]]
        matrix = data["vectors"].astype(np.float32)
    if matrix.ndim != 2 or matrix.shape[0] != len(vocab) or not np.isfinite(matrix).all():
        raise ValueError("the local word vectors are unavailable")
    norms = np.linalg.norm(matrix, axis=1, keepdims=True)
    if np.any(norms == 0) or len(set(vocab)) != len(vocab):
        raise ValueError("the local word vectors are invalid")
    # The bundled float16 vectors are almost normalized. Renormalize once so
    # close scores and future replacement files still use cosine similarity.
    matrix /= norms
    matrix.flags.writeable = False
    return vocab, matrix, {word: i for i, word in enumerate(vocab)}


def ranking(secret: str) -> np.ndarray:
    """A complete, stable permutation of ranks; the answer is always rank one."""
    vocab, matrix, index = vectors()
    secret_index = index[secret]
    similarities = matrix @ matrix[secret_index]
    order = np.argsort(-similarities, kind="stable")
    # Identical vectors must never make a synonym the answer.
    order = np.concatenate(([secret_index], order[order != secret_index]))
    ranks = np.empty(len(vocab), dtype=np.int32)
    ranks[order] = np.arange(1, len(vocab) + 1)
    return ranks


def colour_of(rank: int):
    return CLOSE if rank <= 300 else NEAR if rank <= 1500 else FAR


def band_of(rank: int | None) -> str:
    if rank is None:
        return "Explore"
    return "Found" if rank == 1 else "Close" if rank <= 300 else "Nearer" if rank <= 1500 else "Far away"


def proximity_of(rank: int | None, vocabulary: int) -> float:
    if rank is None:
        return 0.0
    return 1.0 - min(1.0, max(0.0, math.log(max(1, rank)) / math.log(max(2, vocabulary))))


@register
class Contexto(Game):
    name = "contexto"
    title = "Contexto"
    blurb = "Follow meaning toward the secret word. Rank one is the answer."
    min_players = 1
    max_players = 4

    def setup(self):
        vocab, _, index = vectors()
        requested = self.options.get("word", "")
        if not isinstance(requested, str):
            raise ValueError("word must be text")
        word = requested.lower().strip()
        if word and (not re.fullmatch(r"[a-z]{1,32}", word) or word not in index):
            raise ValueError("that word is not in the list")
        seed = self.options.get("seed")
        if seed is not None and (isinstance(seed, bool) or not isinstance(seed, (str, int))):
            raise ValueError("seed must be an integer or text")
        if not word:
            pool = [w for w in vocab[300:6000] if 4 <= len(w) <= 12 and w.isascii() and w.isalpha()]
            if not pool:
                raise ValueError("the local word list has no playable answers")
            word = random.Random(seed).choice(pool)
        self.secret = word
        self.ranks = ranking(word)
        self.guesses: list[tuple[str, int, str]] = []
        self.orders: dict[str, int] = {}
        self.latest: tuple[str, int, str] | None = None
        self.best: int | None = None
        self.gave_up = False
        self.receipt = 0
        self.repeated = False
        self.message = "Follow meaning. Rank 1 is the word."

    def apply(self, move: dict, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(move, dict):
            return {"error": "send a word"}
        if "give_up" in move:
            if move["give_up"] is not True or "word" in move or "guess" in move:
                return {"error": "reveal must be true, without a word"}
            return self.give_up()
        if "word" in move and "guess" in move:
            return {"error": "send one word"}
        word = move.get("word", move.get("guess", ""))
        if not isinstance(word, str):
            return {"error": "one word"}
        word = word.strip().lower()
        # Kept for old clients; the native board uses an explicit reveal action.
        if word == "give up":
            return self.give_up()
        return self.guess(word, player)

    def hear(self, text: str, player: str) -> dict | None:
        if not isinstance(text, str):
            return None
        spoken = text.lower().strip()
        if spoken in ("give up", "i give up", "reveal", "tell me"):
            return self.give_up()
        match = _WORD.fullmatch(spoken)
        if not match or match.group(1) not in vectors()[2]:
            return None
        return self.guess(match.group(1), player)

    def guess(self, word: str, player: str) -> dict:
        if self.over:
            return {"error": "the game is over"}
        if not isinstance(word, str) or not re.fullmatch(r"[a-z]{1,32}", word):
            return {"error": "one word"}
        _, _, index = vectors()
        if word not in index:
            return {"error": f"{word} is not in the list"}
        rank = int(self.ranks[index[word]])
        self.receipt += 1
        self.repeated = word in self.orders
        self.latest = (word, rank, player)
        if self.repeated:
            # Duplicate guesses still acknowledge the input and put that word
            # back on the dial. They never add a try or alter attribution.
            self.message = f"Already explored {word.upper()}: rank {rank}."
            self.changed()
            return {"word": word, "rank": rank, "again": True, "receipt": self.receipt,
                    "best": self.best, "guesses": len(self.guesses)}
        self.orders[word] = len(self.guesses) + 1
        self.guesses.append(self.latest)
        self.guesses.sort(key=lambda guess: guess[1])
        self.best = rank if self.best is None else min(self.best, rank)
        if word == self.secret:
            self.finish(won=True, winner=player if len(self.players) > 1 else None,
                        message=f"{word.upper()} in {len(self.guesses)}.")
        else:
            self.message = f"{word.upper()}, rank {rank}. Lower is closer."
            self.changed()
        return {"word": word, "rank": rank, "best": self.best,
                "guesses": len(self.guesses), "receipt": self.receipt}

    def give_up(self) -> dict:
        if self.over:
            return {"error": "the game is over"}
        self.gave_up = True
        self.finish(won=False, message=f"It was {self.secret.upper()}.")
        return {"secret": self.secret}

    def state(self) -> dict:
        size = len(vectors()[0])
        rank = self.latest[1] if self.latest else None
        return {"guesses": [{"word": word, "rank": r, "who": who, "order": self.orders[word]}
                            for word, r, who in self.guesses],
                "best": self.best, "best_word": self.guesses[0][0] if self.guesses else None,
                "count": len(self.guesses), "receipt": self.receipt, "vocabulary": size,
                "band": band_of(rank), "proximity": proximity_of(rank, size),
                "last": {"word": self.latest[0], "rank": rank, "again": self.repeated} if self.latest else None,
                "gave_up": self.gave_up, "secret": self.secret if self.over else None}

    def voice_words(self) -> list[str]:
        return vectors()[0][:3000]

    def frame_at(self, size: int, t: float):
        canvas = blank(size)
        canvas[:] = GROUND
        rank = 1 if self.over else self.latest[1] if self.latest else None
        color = PAPER if self.gave_up else colour_of(rank) if rank else MUTED
        proximity = proximity_of(rank, len(vectors()[0]))
        # These normalized centres and ticks match ContextoBoard's artwork.
        for tick in range(41):
            angle = math.radians(150 + 240 * tick / 40)
            inner = (size * (.5 + .292 * math.cos(angle)), size * (.39 + .292 * math.sin(angle)))
            outer = (size * (.5 + .325 * math.cos(angle)), size * (.39 + .325 * math.sin(angle)))
            lit = rank is not None and tick <= round(proximity * 40)
            line(canvas, inner, outer, color if lit else TRACK, max(1, round(size * .009)))
        small = max(1, round(size * .027 / 7))
        if size >= 128:
            text_centred(canvas, "RANK" if rank else "FIND", size // 2, round(size * .205), MUTED, small)
        digits = str(rank) if rank else "?"
        numeral = max(1, round(size * .20 / 7))
        while numeral > 1 and text_width(digits, numeral) > size * .56:
            numeral -= 1
        text_centred(canvas, digits, size // 2, round(size * .355 - 3.5 * numeral), color, numeral)
        band = "REVEALED" if self.gave_up else band_of(rank).upper()
        if size < 128:
            band = "SHOWN" if self.gave_up else "BEGIN" if rank is None else "FAR" if rank > 1500 else "NEAR" if rank > 300 else band
        band_scale = max(1, int(size * .038 / 7))
        text_centred(canvas, band, size // 2, round(size * .52), color, band_scale)
        word = self.secret if self.over else self.latest[0] if self.latest else "FIRST WORD"
        if size < 128 and not self.latest and not self.over:
            word = "GUESS"
        word_scale = max(1, int(size * .066 / 7))
        text_scrolled(canvas, word.upper(), round(size * .08), round(size * .685), round(size * .84),
                      t, PAPER, word_scale, speed=max(7, size * .11))
        fill(canvas, round(size * .08), round(size * .835), round(size * .84), max(1, round(size * .003)), TRACK)
        footer = f"BEST {self.best}" if self.best is not None else "1 WINS"
        if size >= 160:
            footer = f"BEST {self.best}" if self.best is not None else "RANK 1 IS THE WORD"
            if self.best is not None:
                footer += f"  /  {len(self.guesses)} {'TRY' if len(self.guesses) == 1 else 'TRIES'}"
        footer_scale = max(1, int(size * .029 / 7))
        text_centred(canvas, footer, size // 2, round(size * .895), MUTED, footer_scale)
        return canvas
