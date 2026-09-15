"""Posters: the tab title cleaned, the TMDB lookup with its cache, the
chain source, the show header, and a portrait poster cut square.

    .venv/bin/python -m pytest brain/tests/test_posters.py -q
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.posters import (Posters, PosterSource, clean_title, encode_show, decode_show,   # noqa: E402
                           HIT_TTL_S, MISS_TTL_S, SHOW_FRESH_S)
from brain.nowplaying.applemusic import _decode_show                                   # noqa: E402
from brain.art.pipeline import square, prepare                                          # noqa: E402


def test_clean_title():
    assert clean_title("Severance | Apple TV+")[0] == "Severance"
    assert clean_title("Watch Severance Season 2 Episode 4 - Paramount+")[0] == "Severance"
    assert clean_title("Breaking Bad S1 E1 Pilot | Netflix")[0] == "Breaking Bad"
    assert clean_title("The Bear: S3:E2 Next")[0] == "The Bear"
    assert clean_title("Oppenheimer (2023) - Prime Video")[0] == "Oppenheimer"
    assert clean_title("Now Playing: Dune: Part Two")[:2] == ["Dune: Part Two", "Dune"]
    assert clean_title("Mission: Impossible - Dead Reckoning Part One | Paramount+")[0] == "Mission: Impossible Dead Reckoning Part One"
    assert clean_title("Netflix") == []
    assert clean_title("") == []


TV = {"results": [{"id": 95396, "name": "Severance", "first_air_date": "2022-02-17",
                   "poster_path": "/lFf6LLrQjYldcZItygKkKUtbdP.jpg", "overview": "Mark leads a team..."}]}
MOVIE = {"results": [{"id": 872585, "title": "Oppenheimer", "release_date": "2023-07-19",
                      "poster_path": "/8Gxv8gSFCU0XGDykEGv7zR1n2ua.jpg"}]}
NOTHING = {"results": []}


def fake_fetch(calls, table):
    def fetch(path, params):
        calls.append((path, params["query"]))
        return table.get((path, params["query"].lower()), NOTHING)
    return fetch


def test_lookup_tv_first_then_film_then_cached(tmp_path):
    calls, clock = [], [1_760_000_000.0]
    table = {("/search/tv", "severance"): TV, ("/search/movie", "oppenheimer"): MOVIE}
    p = Posters(api_key="0123456789abcdef0123456789abcdef", path=str(tmp_path / "p.json"),
                fetch=fake_fetch(calls, table), clock=lambda: clock[0])
    hit = p.lookup("Severance | Apple TV+")
    assert hit["kind"] == "tv" and hit["year"] == 2022 and hit["poster"].endswith("lFf6LLrQjYldcZItygKkKUtbdP.jpg")
    assert hit["poster"].startswith("https://image.tmdb.org/t/p/w500/")
    assert calls == [("/search/tv", "Severance")]
    film = p.lookup("Oppenheimer (2023) - Prime Video")
    assert film["kind"] == "movie" and film["year"] == 2023
    assert calls[1:] == [("/search/tv", "Oppenheimer"), ("/search/movie", "Oppenheimer")]
    n = len(calls)
    assert p.lookup("Severance | Apple TV+")["id"] == 95396 and len(calls) == n       # cached
    assert p.lookup("Some Stream Nobody Knows") is None
    m = len(calls)
    assert p.lookup("Some Stream Nobody Knows") is None and len(calls) == m          # a miss is cached too
    clock[0] += MISS_TTL_S + 1
    p.lookup("Some Stream Nobody Knows")
    assert len(calls) == m + 2                                                      # and asked again after a day
    st = p.status()
    assert st["key_set"] and st["posters"] == 2 and st["last"]["title"] == "Oppenheimer"
    again = Posters(api_key="0123456789abcdef0123456789abcdef", path=str(tmp_path / "p.json"),
                    fetch=fake_fetch(calls, table), clock=lambda: clock[0])
    k = len(calls)
    assert again.lookup("Severance | Apple TV+")["name"] == "Severance" and len(calls) == k   # from disk
    clock[0] += HIT_TTL_S + 1
    again.lookup("Severance | Apple TV+")
    assert len(calls) == k + 1


def test_no_key_means_no_lookup(tmp_path):
    calls = []
    p = Posters(api_key="", path=str(tmp_path / "p.json"), fetch=fake_fetch(calls, {}))
    assert p.lookup("Severance") is None and calls == [] and not p.ready


class FakeMac:
    def __init__(self):
        self.show = None


def test_poster_source_answers_only_for_a_fresh_known_show(tmp_path):
    calls, clock = [], [1_760_000_000.0]
    table = {("/search/tv", "severance"): TV}
    posters = Posters(api_key="0123456789abcdef0123456789abcdef", path=str(tmp_path / "p.json"),
                      fetch=fake_fetch(calls, table), clock=lambda: clock[0])
    mac = FakeMac()
    src = PosterSource(mac, posters, clock=lambda: clock[0])
    assert src.get_current() is None
    mac.show = {"title": "Severance | Apple TV+", "artist": "", "bundle": "com.apple.Safari",
                "app": "Safari", "duration_ms": 3_000_000, "progress_ms": 120_000, "seen": clock[0]}
    now = src.get_current()
    assert now.track_id == "show:tv:95396" and now.title == "Severance" and now.artist == "Series, 2022"
    assert now.art_url.endswith(".jpg") and now.is_playing and now.progress_ms == 120_000
    mac.show["progress_ms"] = 130_000
    assert src.get_current().progress_ms == 130_000 and len(calls) == 1          # no second lookup
    clock[0] += SHOW_FRESH_S + 1
    assert src.get_current() is None                                              # the show is over
    mac.show = {"title": "Nothing Known", "seen": clock[0]}
    assert src.get_current() is None and src.get_current() is None
    assert len(calls) == 3                                                        # tv and movie, once


def test_show_header_round_trip():
    show = {"title": "Severance | Apple TV+", "artist": "", "bundle": "com.apple.Safari", "seen": 1.5}
    packed = encode_show(show)
    assert decode_show(packed) == show and _decode_show(packed) == show
    assert decode_show(None) is None and decode_show("not base64!!") is None and _decode_show("") is None


def test_a_poster_is_cut_square_not_squashed():
    poster = Image.new("RGB", (200, 300), (0, 0, 0))
    px = poster.load()
    for y in range(300):
        for x in range(200):
            px[x, y] = (255, 0, 0) if y < 100 else (0, 255, 0) if y < 200 else (0, 0, 255)
    sq = square(poster)
    assert sq.size == (200, 200)
    a = np.asarray(sq)
    assert tuple(a[0, 0]) == (255, 0, 0) and tuple(a[199, 0]) == (0, 0, 255)   # a bit above the middle
    assert (a[:, :, 1] == 255).sum() == 100 * 200                                  # the whole middle band
    wide = square(Image.new("RGB", (300, 100)))
    assert wide.size == (100, 100)
    out = prepare(poster, 64, unsharp_percent=0)
    assert out.size == (64, 64)
