"""Fetch and cache cover art (Spotify 640x640 now; Cover Art Archive up to
1200x1200 at S3, same cache, keyed by URL).

Show me also sends pictures from the open web through here, and those can be
anything: a 100 megapixel panorama decodes to more than the Pi's whole
990 MB. So a download stops past MAX_BYTES, a JPEG decodes at a reduced
scale (the wall never needs more than 192 pixels), and a picture over
MAX_PIXELS is refused before it is decoded. A caller that has a smaller copy
(a thumbnail) falls back to it."""
import base64
import hashlib
import io
import os
import urllib.parse

import requests
from PIL import Image

CACHE_DIR = os.path.expanduser("~/.cache/album-art-matrix")
# Wikimedia refuses a download with no descriptive User-Agent (403), and
# the picture of the Eiffel Tower comes from there. Every fetch says who it is.
UA = "album-art-matrix/1.0 (github.com/jke48222/album-art-matrix)"
MAX_BYTES = 15 * 1024 * 1024        # a download larger than this is abandoned
MAX_PIXELS = 24_000_000             # width x height, checked before the decode: about
                                    # 100 MB as RGBA, which the Pi can hold beside the render loop
DRAFT = (1024, 1024)                # a JPEG decodes at the smallest scale at least this big


class TooLarge(ValueError):
    """A picture too big to decode safely on the wall."""


def _decode(data: bytes) -> Image.Image:
    img = Image.open(io.BytesIO(data))
    # Reading the header costs nothing. The decode is what takes memory, so
    # a JPEG is told to decode at a fraction of its size (1/2 to 1/8) and
    # anything still too large is refused before the decode starts.
    img.draft("RGB", DRAFT)
    if img.width * img.height > MAX_PIXELS:
        raise TooLarge(f"{img.width}x{img.height} is too large to show")
    img.load()          # force the full decode; a truncated file fails HERE
    return img


def _download(url: str, timeout: float) -> bytes:
    """The body, streamed and capped at MAX_BYTES."""
    with requests.get(url, timeout=timeout, headers={"User-Agent": UA}, stream=True) as resp:
        resp.raise_for_status()
        try:
            declared = int(resp.headers.get("Content-Length") or 0)
        except (TypeError, ValueError):
            declared = 0
        if declared > MAX_BYTES:
            raise TooLarge(f"{declared} bytes is too large to fetch")
        out = bytearray()
        for chunk in resp.iter_content(chunk_size=64 * 1024):
            out += chunk
            if len(out) > MAX_BYTES:
                raise TooLarge("the picture is too large to fetch")
        return bytes(out)


# Pictures the brain already holds, by the URL it serves them at: AirPlay
# artwork (brain/nowplaying/airplay.py) is read straight from here, while the
# phone fetches the same URL from the control port.
LOCAL: dict[str, bytes] = {}


def fetch_art(url: str, timeout: float = 15.0) -> Image.Image:
    if url in LOCAL:
        return _decode(LOCAL[url])
    if url.startswith("data:"):
        # The Mac's Now Playing hands over artwork as bytes, not a link. No
        # disk cache: the bytes are already in hand.
        head, _, payload = url.partition(",")
        data = (base64.b64decode(payload) if head.endswith(";base64")
                else urllib.parse.unquote_to_bytes(payload))
        return _decode(data)
    os.makedirs(CACHE_DIR, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:24]
    path = os.path.join(CACHE_DIR, key + ".img")
    if os.path.exists(path):
        try:
            if os.path.getsize(path) > MAX_BYTES:
                raise TooLarge("cached picture is too large")
            with open(path, "rb") as fh:
                data = fh.read()
            return _decode(data)
        except Exception:           # a poisoned entry heals by refetching
            try:
                os.remove(path)
            except OSError:
                pass
    data = _download(url, timeout)
    # Decode BEFORE caching: a captive portal or error page served as 200
    # must fail here, not become a permanent cache entry for this URL.
    img = _decode(data)
    with open(path, "wb") as fh:
        fh.write(data)
    return img
