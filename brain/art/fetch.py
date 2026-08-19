"""Fetch and cache cover art (Spotify 640x640 now; Cover Art Archive up to
1200x1200 at S3 — same cache, keyed by URL)."""
import hashlib
import io
import os

import requests
from PIL import Image

CACHE_DIR = os.path.expanduser("~/.cache/album-art-matrix")


def fetch_art(url: str, timeout: float = 15.0) -> Image.Image:
    os.makedirs(CACHE_DIR, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:24]
    path = os.path.join(CACHE_DIR, key + ".img")
    if os.path.exists(path):
        with open(path, "rb") as fh:
            data = fh.read()
    else:
        resp = requests.get(url, timeout=timeout)
        resp.raise_for_status()
        data = resp.content
        with open(path, "wb") as fh:
            fh.write(data)
    return Image.open(io.BytesIO(data))
