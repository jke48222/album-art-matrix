"""Word lists for the games, built once from a public frequency list
(hermitdave/FrequencyWords, OpenSubtitles 2018) filtered through the
system dictionary, and kept in brain/games/words/:

    common.txt    30,000 everyday words by frequency, 3 to 12 letters
    answers5.txt  2,400 five-letter words worth guessing (no plain plurals)
    valid5.txt    every five-letter word the dictionary knows, plus those
"""
from __future__ import annotations

import os
from functools import lru_cache

HERE = os.path.join(os.path.dirname(__file__), "words")


@lru_cache(maxsize=None)
def _read(name: str) -> tuple[str, ...]:
    try:
        with open(os.path.join(HERE, name), encoding="utf-8") as fh:
            return tuple(w.strip() for w in fh if w.strip())
    except OSError:
        return ()


def common(min_len: int = 3, max_len: int = 12, limit: int | None = None) -> list[str]:
    out = [w for w in _read("common.txt") if min_len <= len(w) <= max_len]
    return out[:limit] if limit else out


def answers5() -> tuple[str, ...]:
    return _read("answers5.txt")


@lru_cache(maxsize=None)
def valid5() -> frozenset[str]:
    return frozenset(_read("valid5.txt")) | frozenset(answers5())


@lru_cache(maxsize=None)
def common_set() -> frozenset[str]:
    return frozenset(_read("common.txt"))
