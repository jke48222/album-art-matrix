"""The shelf: folding names, matching songs to pressings against forty
tricky releases, syncing pages, the pressing on a worker, and the corner
mark at both sizes.

    .venv/bin/python -m pytest brain/tests/test_shelf.py -q
"""
import os
import sys
import time

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying import NowPlaying                                  # noqa: E402
from brain.shelf import Shelf, fold, fold_artist        # noqa: E402
from brain.art.mark import owned_mark, geometry                           # noqa: E402

OUT = os.environ.get("VOICE_TEST_OUT", "")


def rel(i, title, artists, year=2016, label="Boys Don't Cry", catno="BDC 1", fmt=("Vinyl", "LP")):
    return {"basic_information": {"id": i, "title": title, "artists": [{"name": a} for a in artists],
                                  "year": year, "labels": [{"name": label, "catno": catno}],
                                  "formats": [{"name": fmt[0], "descriptions": list(fmt[1:])}],
                                  "cover_image": f"https://img/{i}.jpg", "genres": ["Pop"]},
            "date_added": "2024-01-01T00:00:00-08:00", "rating": 4}


SHELF = [
    rel(1, "Blonde", ["Frank Ocean"]),
    rel(2, "Blond", ["Frank Ocean"], fmt=("CD",)),
    rel(3, "The Dark Side Of The Moon", ["Pink Floyd"], 1973, "Harvest", "SHVL 804"),
    rel(4, "Melodrama", ["Lorde"], 2017),
    rel(5, "Currents", ["Tame Impala"], 2015),
    rel(6, "Rumours", ["Fleetwood Mac"], 1977),
    rel(7, "Abbey Road", ["The Beatles"], 1969),
    rel(8, "SOUR", ["Olivia Rodrigo"], 2021),
    rel(9, "Kid A", ["Radiohead"], 2000),
    rel(10, "Random Access Memories", ["Daft Punk"], 2013),
    rel(11, "MTV Unplugged In New York", ["Nirvana"], 1994),
    rel(12, "Norman Fucking Rockwell!", ["Lana Del Rey"], 2019),
    rel(13, "Nights (2)", ["Nights (2)"], 2001),
    rel(14, "In Rainbows", ["Radiohead"], 2007),
    rel(15, "Igor", ["Tyler, The Creator"], 2019),
    rel(16, "channel ORANGE", ["Frank Ocean"], 2012),
    rel(17, "7TH YEAR: A Moment Of Stillness In The Thorns", ["TOMORROW X TOGETHER"], 2026),
    rel(18, "UNFORGIVEN", ["LE SSERAFIM"], 2023),
    rel(19, "Now That's What I Call Music! 50", ["Various"], 2001),
    rel(20, "Live At Leeds", ["The Who"], 1970),
    rel(21, "Homogenic", ["Björk"], 1997),
    rel(22, "Lemonade", ["Beyoncé"], 2016),
    rel(23, "Agents Of Fortune", ["Blue Öyster Cult"], 1976),
    rel(24, "Preacher's Daughter", ["Ethel Cain"], 2022),
    rel(25, "Sgt. Pepper's Lonely Hearts Club Band", ["The Beatles"], 1967),
    rel(26, "Bridge Over Troubled Water", ["Simon & Garfunkel"], 1970),
    rel(27, "?", ["XXXTentacion"], 2018),
    rel(28, "Vol. 3: (The Subliminal Verses)", ["Slipknot"], 2004),
    rel(29, "Guardians Of The Galaxy: Awesome Mix Vol. 1 (Original Motion Picture Soundtrack)", ["Various"], 2014),
    rel(30, "Un Verano Sin Ti", ["Bad Bunny"], 2022),
    rel(31, "Whenever You Need Somebody", ["Rick Astley"], 1987),
    rel(32, "My Beautiful Dark Twisted Fantasy", ["Kanye West"], 2010),
    rel(33, "Blond (2)", ["Frank Ocean"], fmt=("Vinyl", "LP", "Unofficial Release")),
    rel(34, "Ctrl", ["SZA"], 2017),
    rel(35, "Discovery", ["Daft Punk"], 2001),
    rel(36, "Silk Sonic", ["Bruno Mars", "Anderson .Paak"], 2021),
    rel(37, "An Evening With Silk Sonic", ["Silk Sonic"], 2021),
    rel(38, "The Wall", ["Pink Floyd"], 1979),
    rel(39, "Rumours (Deluxe Edition)", ["Fleetwood Mac"], 2013, fmt=("CD",)),
    rel(40, "Live", ["Donny Hathaway"], 1972),
]


def test_fold():
    assert fold("The Dark Side Of The Moon") == "dark side of the moon"
    assert fold("Nights (2)") == "nights"
    assert fold("Norman Fucking Rockwell!") == "norman fucking rockwell"
    assert fold("Blonde [Deluxe Edition]") == "blonde"
    assert fold("Rumours (Deluxe Edition)") == fold("Rumours") == fold("Rumours - Deluxe")
    assert fold("Björk") == "bjork" and fold("Beyoncé") == "beyonce"
    assert fold("Blue Öyster Cult") == fold("Blue Oyster Cult")
    assert fold("?") == "" and fold("") == ""
    assert fold("Sgt. Pepper's Lonely Hearts Club Band") == "sgt pepper s lonely hearts club band"
    assert fold_artist("Tyler, The Creator") == "tyler"          # a comma is a list to a folder
    assert fold_artist("Frank Ocean feat. Beyoncé") == "frank ocean"
    assert fold_artist("Simon & Garfunkel") == "simon"
    assert fold_artist("Bruno Mars, Anderson .Paak & Silk Sonic") == "bruno mars"
    assert fold_artist("Silk Sonic") == "silk sonic"


class FakeCtrl:
    def get(self):
        return {}


def shelf(tmp_path, pages=None):
    calls = []
    def fetch(path, params):
        calls.append((path, dict(params)))
        if "collection" in path:
            page = params.get("page", 1)
            chunk = SHELF[(page - 1) * 15:page * 15]
            return {"pagination": {"pages": 3}, "releases": chunk}
        if path.startswith("/releases/"):
            return {"country": "US", "released": "2016-08-20", "notes": "Gatefold."}
        if path.startswith("/marketplace/stats/"):
            return {"lowest_price": {"value": 42.5, "currency": "USD"}, "num_for_sale": 7}
        raise LookupError(path)
    s = Shelf(FakeCtrl(), token="tok", user="jalen", path=str(tmp_path / "shelf.json"), fetch=fetch,
              clock=lambda: 1_760_000_000.0)
    return s, calls


def test_sync_reads_every_page_and_survives_a_restart(tmp_path):
    import brain.shelf as mod
    mod.PACE_S = 0.0
    s, calls = shelf(tmp_path)
    assert s.sync() == 40
    assert [c[1]["page"] for c in calls if "collection" in c[0]] == [1, 2, 3]
    again = Shelf(FakeCtrl(), token="tok", user="jalen", path=str(tmp_path / "shelf.json"),
                  fetch=lambda *a: {}, clock=lambda: 1_760_000_000.0)
    assert again.status()["releases"] == 40 and again.status()["synced_at"] == 1_760_000_000.0


def now(title, artist, album):
    return NowPlaying(track_id="x", title=title, artist=artist, album=album, art_url=None,
                      progress_ms=None, duration_ms=None, is_playing=True)


def test_matching_is_forgiving_and_prefers_vinyl(tmp_path):
    import brain.shelf as mod
    mod.PACE_S = 0.0
    s, _ = shelf(tmp_path)
    s.sync()
    def rid(title, artist, album):
        p = s.owned(now(title, artist, album))
        return p["release_id"] if p else None
    assert rid("Nights", "Frank Ocean", "Blonde") == 1                       # vinyl over the CD
    assert rid("Time", "Pink Floyd", "Dark Side of the Moon") == 3
    assert rid("Come Together", "The Beatles", "Abbey Road (Remastered)") == 7
    assert s.owned(now("Green Light", "Lorde", "Melodrama"))["year"] == 2017
    assert rid("EARFQUAKE", "Tyler, The Creator", "IGOR") == 15
    assert rid("Venice Bitch", "Lana Del Rey", "Norman Fucking Rockwell!") == 12
    assert rid("Stick With You", "TOMORROW X TOGETHER", "7TH YEAR: A Moment of Stillness in the Thorns - EP") == 17
    assert rid("Eve, Psyche & The Bluebeard's wife", "LE SSERAFIM", "UNFORGIVEN") == 18
    assert rid("Whatever", "Someone", "Now That's What I Call Music! 50") == 19   # various
    assert rid("Nights", "Frank Ocean", "Endless") is None
    assert rid("Pyramids", "Frank Ocean", "channel ORANGE") == 16
    assert rid("Nights", "Frank Ocean", "?") is None
    assert rid("Karma Police", "Radiohead", "OK Computer") is None
    assert rid("Jóga", "Björk", "Homogenic") == 21
    assert rid("Formation", "Beyoncé", "Lemonade") == 22
    assert rid("(Don't Fear) The Reaper", "Blue Oyster Cult", "Agents of Fortune") == 23
    assert rid("American Teenager", "Ethel Cain", "Preacher's Daughter") == 24
    assert rid("A Day In The Life", "The Beatles", "Sgt. Pepper's Lonely Hearts Club Band (Deluxe Edition)") == 25
    assert rid("The Boxer", "Simon & Garfunkel", "Bridge over Troubled Water") == 26
    assert rid("SAD!", "XXXTENTACION", "?") is None                               # a "?" album is unknown
    assert rid("Duality", "Slipknot", "Vol. 3: (The Subliminal Verses)") == 28
    assert rid("Hooked on a Feeling", "Blue Swede", "Guardians of the Galaxy: Awesome Mix Vol. 1 (Original Motion Picture Soundtrack)") == 29
    assert rid("Tití Me Preguntó", "Bad Bunny", "Un Verano Sin Ti") == 30
    assert rid("Never Gonna Give You Up", "Rick Astley", "Whenever You Need Somebody") == 31
    assert rid("Runaway", "Kanye West", "My Beautiful Dark Twisted Fantasy") == 32
    assert rid("Love Galore", "SZA", "Ctrl") == 34
    assert rid("One More Time", "Daft Punk", "Discovery") == 35
    assert rid("Leave the Door Open", "Bruno Mars, Anderson .Paak & Silk Sonic", "An Evening With Silk Sonic") == 37
    assert rid("Comfortably Numb", "Pink Floyd", "The Wall") == 38
    assert rid("Dreams", "Fleetwood Mac", "Rumours (Deluxe Edition)") == 6          # the vinyl, not the deluxe CD
    assert rid("The Ghetto", "Donny Hathaway", "Live") == 40
    assert rid("Hey Jude", "The Beatles", "Live") is None                          # a short title needs its artist
    assert rid("The Wall", "Someone Else", "The Wall") is None


def test_pressing_enrichment_and_listing(tmp_path):
    import brain.shelf as mod
    mod.PACE_S = 0.0
    s, calls = shelf(tmp_path)
    s.sync()
    p = s.owned(now("Nights", "Frank Ocean", "Blonde"))
    assert p["label"] == "Boys Don't Cry" and p["catno"] == "BDC 1" and "price" not in p
    assert p["url"] == "https://www.discogs.com/release/1"
    p2 = s.enrich(1)
    assert p2["country"] == "US" and p2["price"]["lowest"] == 42.5 and p2["price"]["for_sale"] == 7
    n = len(calls)
    s.enrich(1)                                                   # cached
    assert len(calls) == n
    lst = s.listing(journal=[{"album": "Blonde", "artist": "Frank Ocean"}] * 3)
    blonde = next(x for x in lst if x["release_id"] == 1)
    assert blonde["plays"] == 3 and len(lst) == 40


def test_note_playing_fills_in_the_price_off_the_render_loop(tmp_path):
    import brain.shelf as mod
    mod.PACE_S = 0.0
    s, calls = shelf(tmp_path)
    s.sync()
    assert s.note_playing("OK Computer", "Radiohead") is None and s.playing is None
    p = s.note_playing("Melodrama", "Lorde")
    assert p["release_id"] == 4 and "price" not in p                # answered at once, without Discogs
    for _ in range(100):
        if s.playing.get("price"):
            break
        time.sleep(0.02)
    assert s.playing["price"]["lowest"] == 42.5 and s.playing["country"] == "US"
    s.note_playing("?", "Anyone")
    assert s.playing is None


def test_unconfigured_shelf_does_nothing(tmp_path):
    s = Shelf(FakeCtrl(), path=str(tmp_path / "shelf.json"), fetch=lambda *a: (_ for _ in ()).throw(AssertionError("no")))
    assert s.sync() == 0 and s.owned(now("a", "b", "c")) is None
    s.tick()
    assert s.status()["token_set"] is False


def test_the_mark_at_both_sizes():
    assert geometry(64)[0] == 5 and geometry(192)[0] == 11
    strips = []
    for size, scale in ((64, 4), (192, 2)):
        light = np.full((size, size, 3), 220, np.uint8)
        dark = np.full((size, size, 3), 25, np.uint8)
        g = np.linspace(0, 255, size).astype(np.uint8)
        grad = np.stack([np.tile(g, (size, 1))] * 3, -1)
        ml, md = owned_mark(light), owned_mark(dark)
        d, inset, _, outline = geometry(size)
        box = d + (2 if outline else 0)
        changed_l = (ml != light).any(-1)
        assert changed_l.sum() > 0
        ys, xs = np.nonzero(changed_l)
        assert xs.max() == size - inset - 1 + (1 if outline else 0) and ys.max() == xs.max()
        assert xs.min() >= size - inset - box and ys.min() >= size - inset - box
        cy, cx = size - inset - d + d // 2, size - inset - d + d // 2 - max(1, d // 4)
        assert (ml[cy, cx] < 60).all()                                    # dark ink on a light sleeve
        assert (md[cy, cx] > 200).all()                                   # light ink on a dark one
        assert (ml[cy, cx + max(1, d // 4)] > 200).all()                  # the hole, in the other tone
        # nothing else moved
        rest = np.ones((size, size), bool)
        rest[size - inset - box:, size - inset - box:] = False
        assert (ml[rest] == 220).all()
        pil = owned_mark(Image.fromarray(grad))
        assert isinstance(pil, Image.Image)
        strips.append([ml, md, np.array(pil)])
        if OUT:
            n = 3
            canvas = np.zeros((size, n * size + (n - 1) * 4, 3), np.uint8)
            for i, fr in enumerate(strips[-1]):
                canvas[:, i * (size + 4):i * (size + 4) + size] = fr
            Image.fromarray(canvas).resize((canvas.shape[1] * scale, size * scale),
                                           Image.NEAREST).save(os.path.join(OUT, f"shelf-mark-{size}.png"))
