"""Fetch and cache cover art (Spotify 640x640 now; Cover Art Archive up to
1200x1200 at S3 — same cache, keyed by URL)."""
import hashlib
import io
import os

import requests
from PIL import Image

CACHE_DIR = os.path.expanduser("~/.cache/album-art-matrix")


def _decode(data: bytes) -> Image.Image:
    img = Image.open(io.BytesIO(data))
    img.load()          # force the full decode; a truncated file fails HERE
    return img


def fetch_art(url: str, timeout: float = 15.0) -> Image.Image:
    os.makedirs(CACHE_DIR, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:24]
    path = os.path.join(CACHE_DIR, key + ".img")
    if os.path.exists(path):
        with open(path, "rb") as fh:
            data = fh.read()
        try:
            return _decode(data)
        except Exception:           # a poisoned entry heals by refetching
            try:
                os.remove(path)
            except OSError:
                pass
    resp = requests.get(url, timeout=timeout)
    resp.raise_for_status()
    data = resp.content
    # Decode BEFORE caching: a captive portal or error page served as 200
    # must fail here, not become a permanent cache entry for this URL.
    img = _decode(data)
    with open(path, "wb") as fh:
        fh.write(data)
    return img
