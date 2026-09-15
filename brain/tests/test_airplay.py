"""AirPlay: a recorded metadata pipe stream parsed across any chunking into
NowPlaying answers, the progress clock, the artwork's URL, pause and end.

    .venv/bin/python -m pytest brain/tests/test_airplay.py -q
"""
import base64
import io
import os
import time
import sys

from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", ".."))

from brain.nowplaying.airplay import AirPlaySource, Parser, code_of   # noqa: E402
from brain.art import fetch as art_fetch                              # noqa: E402
from brain.art.fetch import fetch_art                                 # noqa: E402


def item(t: str, c: str, data: bytes = b"") -> bytes:
    head = f"<item><type>{t.encode().hex()}</type><code>{c.encode().hex()}</code><length>{len(data)}</length>"
    if not data:
        return (head + "</item>\n").encode()
    return head.encode() + b'\n<data encoding="base64">\n' + base64.b64encode(data) + b"</data></item>\n"


def png_bytes():
    img = Image.new("RGB", (40, 40), (200, 30, 30))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


ART = png_bytes()
STREAM = (item("ssnc", "snam", b"Jalen's iPhone") + item("ssnc", "snua", b"AirPlay/845.5.1")
          + item("ssnc", "pbeg") + item("ssnc", "pvol", b"-15.00,-20.00,-30.00,0.00")
          + item("ssnc", "mdst", b"12345") + item("core", "minm", "Nights".encode())
          + item("core", "asar", "Frank Ocean".encode()) + item("core", "asal", "Blonde".encode())
          + item("core", "asgn", b"R&B") + item("core", "astm", (307_000).to_bytes(4, "big"))
          + item("core", "mper", bytes.fromhex("0123456789abcdef")) + item("ssnc", "mden", b"12345")
          + item("ssnc", "prgr", b"1000/221500/13539700")            # 5 s into 307 s
          + item("ssnc", "PICT", ART))


def test_code_of_and_records_across_chunking():
    assert code_of("636f7265") == "core" and code_of(b"73736e63") == "ssnc" and code_of("zz") == "?"
    whole = Parser().feed(STREAM)
    assert [c for _, c, _ in whole] == ["snam", "snua", "pbeg", "pvol", "mdst", "minm", "asar", "asal",
                                        "asgn", "astm", "mper", "mden", "prgr", "PICT"]
    assert whole[-1][2] == ART and whole[5][2] == b"Nights"
    for n in (1, 7, 64, 1000):
        p, got = Parser(), []
        for i in range(0, len(STREAM), n):
            got.extend(p.feed(STREAM[i:i + n]))
        assert got == whole, n


def test_a_stream_becomes_a_playing_answer_with_art_and_a_clock():
    clock = [1000.0]
    src = AirPlaySource(pipe="/nonexistent", port=8788, host="album-matrix.local", clock=lambda: clock[0])
    assert src.get_current() is None
    for t, c, d in Parser().feed(STREAM):
        src.handle(t, c, d)
    now = src.get_current()
    assert now is not None and now.is_playing
    assert now.title == "Nights" and now.artist == "Frank Ocean" and now.album == "Blonde"
    assert now.track_id.startswith("airplay:") and now.duration_ms == 307_000
    assert now.progress_ms == 5000
    clock[0] += 10.0
    assert src.get_current().progress_ms == 15000                      # the clock runs while playing
    assert now.art_url.startswith("http://album-matrix.local:8788/art/airplay/") and now.art_url.endswith(".png")
    assert art_fetch.LOCAL[now.art_url] == ART
    img = fetch_art(now.art_url)                                        # no network: from the registry
    assert img.size == (40, 40) and img.getpixel((5, 5))[0] > 150
    key = now.art_url.rsplit("/", 1)[1].split(".")[0]
    assert src.art(key)[1] == "image/png"
    st = src.status()
    assert st["state"] == "playing" and st["connected_from"] == "Jalen's iPhone" and st["volume"] == -15.0
    assert st["last"] == "Nights by Frank Ocean" and st["pipe_exists"] is False
    # art arriving after the title changes the id, so the wall re-shows with the sleeve
    before = src.get_current().track_id
    src.handle("ssnc", "PICT", b"")
    assert src.get_current().art_url is None and src.get_current().track_id != before


def test_pause_resume_new_song_and_the_end():
    clock = [1000.0]
    src = AirPlaySource(pipe="/nonexistent", host="w.local", clock=lambda: clock[0])
    for t, c, d in Parser().feed(STREAM):
        src.handle(t, c, d)
    src.handle("ssnc", "pfls", b"")
    paused = src.get_current()
    assert paused is not None and not paused.is_playing and paused.progress_ms == 5000
    clock[0] += 30
    assert src.get_current().progress_ms == 5000                       # no clock while paused
    src.handle("ssnc", "prsm", b"")
    src.handle("ssnc", "prgr", b"1000/221500/13539700")
    assert src.get_current().is_playing
    # the next song: its title first, the art a beat later
    for t, c, d in Parser().feed(item("ssnc", "mdst", b"1") + item("core", "minm", b"Ivy")
                                 + item("core", "asar", b"Frank Ocean") + item("core", "asal", b"Blonde")
                                 + item("ssnc", "mden", b"1")):
        src.handle(t, c, d)
    nxt = src.get_current()
    assert nxt.title == "Ivy" and nxt.art_url is None and nxt.progress_ms is None
    src.handle("ssnc", "PICT", ART)
    assert src.get_current().art_url is not None
    src.handle("ssnc", "pend", b"")
    assert src.get_current() is None and src.status()["state"] == "idle"
    src.handle("ssnc", "pbeg", b"")
    assert src.get_current().title == "Ivy"                             # the same song, started again
    src.handle("ssnc", "disc", b"")
    assert src.get_current() is None and src.status()["connected_from"] == ""


def test_a_malformed_record_does_not_wedge_the_parser():
    bad = b"<item><type>73736e63</type><code>50494354</code><length>99</length></item>\n"
    p = Parser()
    assert p.feed(bad) == []
    got = p.feed(item("ssnc", "pbeg"))
    assert [c for _, c, _ in got] == ["pbeg"]


def test_a_song_without_artwork_gets_its_sleeve_by_name(monkeypatch):
    import brain.show as show
    calls = []
    monkeypatch.setattr(show, "find_art", lambda q: calls.append(q) or {"art_url": "https://is1.example/nights.jpg"})
    clock = [100.0]
    src = AirPlaySource(pipe="/nonexistent", host="w.local", clock=lambda: clock[0])
    for t, c, d in Parser().feed(item("ssnc", "pbeg") + item("ssnc", "mdst", b"1") + item("core", "minm", b"Nights")
                                 + item("core", "asar", b"Frank Ocean") + item("core", "asal", b"Blonde")
                                 + item("ssnc", "mden", b"1")):
        src.handle(t, c, d)
    first = src.get_current()
    assert first.art_url is None and calls == []                       # a moment for the real artwork
    clock[0] += 5.0
    src.get_current()
    for _ in range(100):
        if src.get_current().art_url:
            break
        time.sleep(0.02)
    now = src.get_current()
    assert now.art_url == "https://is1.example/nights.jpg" and calls == ["Frank Ocean Nights"]
    assert now.track_id != first.track_id                               # the wall shows it
    src.get_current()
    assert len(calls) == 1                                               # once a song
