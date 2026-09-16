"""Catalogue search, structured earworm answers and result-face layouts."""
import json
from types import SimpleNamespace

import numpy as np
from PIL import Image

from brain.art.result import ResultFace
from brain.catalog import search
from brain.discover import show
from brain.earworm import Earworm
from brain.features import Features
from brain.tests.test_ask import ctrl
from brain.voice import Command, match_command


class CatalogueHTTP:
    def __init__(self):
        self.calls = []
    def get(self, url, params, timeout):
        self.calls.append(params)
        entity = params["entity"]
        data = ({"collectionName": "Blond", "artistName": "Frank Ocean",
                 "artworkUrl100": "https://a/100x100bb.jpg", "collectionViewUrl": "https://a"}
                if entity == "album" else
                {"trackName": "Nikes", "collectionName": "Blond", "artistName": "Frank Ocean",
                 "artworkUrl100": "https://b/100x100bb.jpg"})
        return SimpleNamespace(raise_for_status=lambda: None,
                               json=lambda: {"results": [data]})


def test_catalogue_prefers_album_and_upgrades_art():
    http = CatalogueHTTP()
    result = search("Blond Frank Ocean", 2, http)
    assert result[0]["title"] == "Blond"
    assert result[0]["art_url"] == "https://a/1200x1200bb.jpg"
    assert [call["entity"] for call in http.calls] == ["album", "song"]


def test_result_face_all_states_and_sizes():
    items = [{"title": "One", "artist": "Artist A", "image": Image.new("RGB", (80, 80), (180, 60, 40))},
             {"title": "Two", "artist": "Artist B", "image": Image.new("RGB", (80, 80), (30, 80, 170))}]
    for size in (64, 192):
        one = ResultFace(size, items[:1])
        assert one.frame_at(0).shape == (size, size, 3)
        assert not np.array_equal(one.frame_at(0), one.frame_at(2))
        two = ResultFace(size, items)
        assert two.frame_at(0).any()
        if size == 64:
            assert not np.array_equal(two.frame_at(0), two.frame_at(2))
        else:
            frame = two.frame_at(0)
            assert frame[:, :size // 2].any() and frame[:, size // 2:].any()


class FakeMessages:
    def create(self, **kwargs):
        assert kwargs["output_config"]["format"]["type"] == "json_schema"
        text = json.dumps({"title": "Song A", "artist": "Artist A", "confidence": .2,
                           "alternatives": [{"title": "Song B", "artist": "Artist B"}]})
        return SimpleNamespace(content=[SimpleNamespace(type="text", text=text)])


class FakeClient:
    messages = FakeMessages()
    def close(self): pass


def test_earworm_low_confidence_shows_two(ctrl):
    ctrl.features = Features({"features": {"earworm": True}})
    ctrl.services_store.data["claude"]["api_key"] = "sk-ant-" + "x" * 20
    shown = []
    ctrl.show_answer = lambda text: None
    ctrl.show_result = lambda items, duration=8: shown.extend(items)
    def catalogue(query, limit):
        letter = "B" if "Song B" in query else "A"
        return [{"title": "Song " + letter, "artist": "Artist " + letter,
                 "album": "Album", "art_url": "https://art/" + letter, "url": None}]
    answer = Earworm(ctrl, lambda key: FakeClient(), catalogue).ask("words I remember")
    assert answer["confidence"] == .2 and len(shown) == 2


def test_show_and_voice_routes(ctrl):
    ctrl.features = Features({"features": {"show": True}})
    shown = []
    ctrl.show_result = lambda items, duration=8: shown.append((items, duration))
    answer = show(ctrl, "Blond", lambda query, limit: [{"title": "Blond", "artist": "Frank Ocean",
        "album": "Blond", "art_url": "https://art", "url": None}])
    assert answer["shown"] and shown[0][1] == 600
    assert match_command("show me the Blond cover") == Command("show", "the blond cover")
    assert match_command("play the Gameboy video") == Command("play", "the gameboy video")
    assert match_command("what song goes hello from the other side") == Command("earworm", "hello from the other side")
