"""Find a record sleeve from words, using Apple's public catalogue search.

The catalogue needs no account or key. Album results come first because a
request to show a cover normally means the release, then songs fill any
remaining choices. Results are small plain dictionaries so Earworm, Show
and future games share one normalization and artwork rule.
"""
import re

import requests

URL = "https://itunes.apple.com/search"


def _art(url):
    return re.sub(r"/\d+x\d+bb", "/1200x1200bb", url or "")


def search(query, limit=5, session=requests):
    if not isinstance(query, str) or not query.strip() or len(query) > 200:
        raise ValueError("query must contain 1 to 200 characters")
    found = []
    seen = set()
    for entity in ("album", "song"):
        response = session.get(URL, params={"term": query.strip(), "media": "music",
                                            "entity": entity, "limit": limit}, timeout=6)
        response.raise_for_status()
        for raw in response.json().get("results", []):
            title = raw.get("collectionName") or raw.get("trackName") or ""
            artist = raw.get("artistName") or ""
            art = _art(raw.get("artworkUrl100") or raw.get("artworkUrl60"))
            key = (title.casefold(), artist.casefold())
            if title and artist and art and key not in seen:
                seen.add(key)
                found.append({"title": title, "artist": artist,
                              "album": raw.get("collectionName") or title,
                              "art_url": art,
                              "url": raw.get("collectionViewUrl") or raw.get("trackViewUrl")})
                if len(found) >= limit:
                    return found
    return found
