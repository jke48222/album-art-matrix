"""Show me: a picture of a thing, or the cover of a record.

"Show me the Eiffel Tower" used to put up the sleeve of whatever song on
iTunes happened to be called that. Plain words now mean a picture unless
they name a record the wall knows, and the words can say which is meant.
"""
import os
import sys

import pytest
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain import show as S                       # noqa: E402
from brain.control import ControlState            # noqa: E402


class FakeResponse:
    def __init__(self, payload):
        self._p = payload

    def json(self):
        return self._p


def itunes_song(name, artist):
    return {"trackName": name, "artistName": artist, "collectionName": f"{name} - Single",
            "artworkUrl100": f"https://itunes/{name.replace(' ', '_')}/100x100bb.jpg"}


def itunes_album(name, artist):
    return {"collectionName": name, "artistName": artist,
            "artworkUrl100": f"https://itunes/{name.replace(' ', '_')}/100x100bb.jpg"}


@pytest.fixture
def world(monkeypatch):
    """The three services, answered from a script per test, and the fetch
    of any picture answered with a small landscape image."""
    script = {"itunes": {"album": [], "song": []}, "wikipedia": [], "openverse": []}
    calls = []

    def fake_get(url, params=None, headers=None, timeout=None):
        params = params or {}
        if url == S.ITUNES:
            calls.append(("itunes", params.get("entity")))
            return FakeResponse({"results": script["itunes"][params["entity"]]})
        if url == S.WIKIPEDIA:
            calls.append(("wikipedia", params.get("gsrsearch")))
            return FakeResponse({"query": {"pages": script["wikipedia"]}})
        if url == S.OPENVERSE:
            calls.append(("openverse", params.get("q")))
            return FakeResponse({"results": script["openverse"]})
        raise AssertionError(url)

    fetched = []

    def fake_fetch(url, timeout=15.0):
        fetched.append(url)
        return Image.new("RGB", (300, 200), (120, 80, 40))

    monkeypatch.setattr(S.requests, "get", fake_get)
    monkeypatch.setattr(S, "fetch_art", fake_fetch)
    script["calls"], script["fetched"] = calls, fetched
    return script


@pytest.fixture
def shower():
    ctrl = ControlState(frame_len=64 * 64 * 3)
    return S.Shower(ctrl)


def wiki_page(title, pic, index=1, disambiguation=False):
    p = {"title": title, "index": index, "thumbnail": {"source": pic}}
    if disambiguation:
        p["pageprops"] = {"disambiguation": ""}
    return p


def test_a_thing_in_the_world_is_a_picture_even_if_a_song_shares_its_name(world, shower):
    world["itunes"]["song"] = [itunes_song("Eiffel Tower", "Nobody Known")]
    world["wikipedia"] = [wiki_page("Eiffel Tower", "https://wiki/eiffel.jpg")]
    out = shower.show("the eiffel tower")
    assert out["shown"] and out["kind"] == "picture"
    assert out["title"] == "Eiffel Tower" and out["art_url"] == "https://wiki/eiffel.jpg"
    assert shower.ctrl.get()["mode"] == "frame" and shower.ctrl.frame_override is not None
    assert world["fetched"] == ["https://wiki/eiffel.jpg"]


def test_a_record_the_wall_knows_is_its_cover(world, shower):
    shower.ctrl.journal_append({"ts": 1, "title": "Nights", "artist": "Frank Ocean",
                                "album": "Blond", "art_url": ""})
    world["itunes"]["album"] = [itunes_album("Blond", "Frank Ocean")]
    world["wikipedia"] = [wiki_page("Blond", "https://wiki/hair.jpg")]
    out = shower.show("blond")
    assert out["kind"] == "cover" and out["artist"] == "Frank Ocean"
    assert not any(c[0] == "wikipedia" for c in world["calls"])


def test_asking_for_the_cover_in_words_gets_the_cover_of_a_stranger(world, shower):
    world["itunes"]["album"] = [itunes_album("Eiffel Tower", "Some Band")]
    world["wikipedia"] = [wiki_page("Eiffel Tower", "https://wiki/eiffel.jpg")]
    assert shower.show("eiffel tower", kind="cover")["kind"] == "cover"
    assert shower.show("the eiffel tower album")["kind"] == "cover"
    assert shower.show("the cover of eiffel tower")["kind"] == "cover"
    assert shower.show("eiffel tower by some band")["kind"] == "cover"


def test_asking_for_a_picture_in_words_gets_a_picture_of_a_known_record(world, shower):
    shower.ctrl.journal_append({"ts": 1, "title": "Nights", "artist": "Frank Ocean",
                                "album": "Blond", "art_url": ""})
    world["itunes"]["album"] = [itunes_album("Blond", "Frank Ocean")]
    world["wikipedia"] = [wiki_page("Blond", "https://wiki/hair.jpg")]
    out = shower.show("a picture of blond")
    assert out["kind"] == "picture" and out["art_url"] == "https://wiki/hair.jpg"
    assert not any(c[0] == "itunes" for c in world["calls"])


def test_disambiguation_pages_are_skipped_and_openverse_is_the_fallback(world, shower):
    world["wikipedia"] = [wiki_page("Mercury", "https://wiki/dab.jpg", disambiguation=True)]
    world["openverse"] = [{"title": "Mercury the planet", "thumbnail": "https://ov/m.jpg",
                           "creator": "NASA", "license": "by"}]
    out = shower.show("mercury")
    assert out["kind"] == "picture" and out["art_url"] == "https://ov/m.jpg"
    assert out["credit"] == "NASA, CC BY"


def test_a_cover_stands_in_when_there_is_no_picture(world, shower):
    world["itunes"]["song"] = [itunes_song("Eiffel Tower", "Nobody Known")]
    out = shower.show("the eiffel tower")
    assert out["kind"] == "cover" and out["artist"] == "Nobody Known"


def test_nothing_anywhere_says_so(world, shower):
    out = shower.show("zxqv plorb")
    assert "could not find a picture or a cover" in out["error"]
    assert shower.ctrl.get()["mode"] != "frame"
