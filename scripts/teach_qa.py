"""Prove a real catalogue preview can be taught without retaining its audio.

Run from the checkout with its venv: python -m scripts.teach_qa. The test
uses a private temporary fingerprint database, prints timings and removes
that database afterward. The owner's library is never changed.
"""
import json
import tempfile
import time

import numpy as np
import requests

from brain.teach import Library, ITUNES, preview_pcm


def main():
    response = requests.get(ITUNES, params={"term": "MALI Tower of Roses", "entity": "song", "limit": 15}, timeout=10)
    response.raise_for_status()
    item = next(x for x in response.json()["results"]
                if x.get("artistName", "").casefold() == "mali"
                and x.get("trackName", "").casefold() == "tower of roses")
    track = {"title": item["trackName"], "artist": item["artistName"],
             "album": item["collectionName"], "duration_ms": item["trackTimeMillis"],
             "art_url": item["artworkUrl100"].replace("100x100bb", "600x600bb"), "isrc": None}
    pcm = preview_pcm(item["previewUrl"])
    with tempfile.TemporaryDirectory(prefix="codex-teach-qa-") as directory:
        library = Library(directory)
        start = time.monotonic()
        ident = library.store(track, pcm, "preview")
        store_s = time.monotonic() - start
        part = np.frombuffer(pcm, dtype='<i2')[3*16000:12*16000].astype(float)
        part += np.random.default_rng(61).normal(0, 100, len(part))
        start = time.monotonic()
        hit = library.query(np.clip(part, -32768, 32767).astype('<i2').tobytes(), 12)
        query_s = time.monotonic() - start
        assert hit and hit[0].title == "Tower of Roses", "Preview did not match"
        library.forget(ident)
        print(json.dumps({"engine": "Olaf C core", "title": hit[0].title, "artist": hit[0].artist,
                          "score": hit[-1], "store_s": round(store_s, 3), "query_s": round(query_s, 3),
                          "audio_retained": False, "library_removed": not library.entries}, indent=2))


if __name__ == '__main__':
    main()
