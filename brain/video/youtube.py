"""YouTube, read the way the YouTube app reads it.

A video on the wall needs two small things: the picture at a size a 64 px
panel can use (144p is already twice too big) and the sound, as a file the
phone can play. YouTube's player endpoint hands both to its own apps, and
the iPhone client's answer comes with plain stream URLs, no signature
puzzle, that download at full speed from the wall (3 MB/s on 2026-09-06).
That is the whole trick. It is YouTube's to change; when it changes, this
file changes, and yt-dlp is the fallback (VIDEO.md).

Nothing is cached and nothing is kept: the URLs expire in hours, and the
audio lives in RAM only while the video is on.

Self-test, from the repo root (the Mac or the Pi):
  .venv/bin/python -m brain.video.youtube https://youtu.be/dQw4w9WgXcQ
"""
from __future__ import annotations

import re
import sys
from typing import Optional

import requests

from . import Media, ResolveError

PLAYER = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
CLIENT = {"clientName": "IOS", "clientVersion": "20.11.6",
          "deviceMake": "Apple", "deviceModel": "iPhone16,2",
          "osName": "iPhone", "osVersion": "18.3.2.22D82",
          "hl": "en", "gl": "US"}
UA = "com.google.ios.youtube/20.11.6 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"
HEADERS = {"User-Agent": UA, "X-YouTube-Client-Name": "5",
           "X-YouTube-Client-Version": CLIENT["clientVersion"],
           "Origin": "https://www.youtube.com"}

_ID = r"([0-9A-Za-z_-]{11})"
_PATTERNS = [
    re.compile(r"(?:youtube\.com|youtube-nocookie\.com)/"
               r"(?:watch\?(?:[^#]*&)?v=|embed/|shorts/|live/|v/)" + _ID),
    re.compile(r"youtu\.be/" + _ID),
]

# The picture: the smallest stream there is, H.264 first because it is the
# cheapest to decode. 144p is 256 px wide; the panel is 64.
_VIDEO_PREF = {160: 0, 278: 1, 394: 2, 133: 3, 242: 4, 395: 5, 134: 6, 18: 7}
# The sound: AAC in an mp4 container, which AVPlayer plays as it is.
_AUDIO_PREF = {140: 0, 139: 1}


def video_id(url: str) -> Optional[str]:
    """The eleven characters, from any of the link shapes YouTube uses."""
    for p in _PATTERNS:
        m = p.search((url or "").strip())
        if m:
            return m.group(1)
    return None


def resolve(url: str, timeout: float = 15.0) -> Media:
    vid = video_id(url)
    if not vid:
        raise ResolveError("not a YouTube link")
    body = {"context": {"client": CLIENT}, "videoId": vid,
            "contentCheckOk": True, "racyCheckOk": True}
    try:
        resp = requests.post(PLAYER, json=body, headers=HEADERS, timeout=timeout)
        resp.raise_for_status()
        d = resp.json()
    except (requests.RequestException, ValueError) as exc:
        raise ResolveError(f"YouTube did not answer: {exc}") from exc
    ps = d.get("playabilityStatus") or {}
    if ps.get("status") != "OK":
        raise ResolveError("YouTube says: " + (ps.get("reason") or ps.get("status") or "unplayable"))
    det = d.get("videoDetails") or {}
    if det.get("isLive"):
        raise ResolveError("live streams are not supported yet")
    sd = d.get("streamingData") or {}
    fmts = (sd.get("formats") or []) + (sd.get("adaptiveFormats") or [])
    videos = [f for f in fmts if f.get("url") and f.get("itag") in _VIDEO_PREF]
    videos.sort(key=lambda f: _VIDEO_PREF[f["itag"]])
    if not videos:
        # whatever small picture stream has a plain url, if any does
        videos = [f for f in fmts if f.get("url")
                  and str(f.get("mimeType", "")).startswith("video/")
                  and (f.get("height") or 9999) <= 360]
        videos.sort(key=lambda f: (f.get("height") or 9999, f.get("bitrate") or 0))
    if not videos:
        ciphered = sum(1 for f in fmts if f.get("signatureCipher"))
        raise ResolveError("YouTube gave no plain picture stream"
                           + (" (only signed ones: the client trick has changed)" if ciphered else ""))
    v = videos[0]
    audios = [f for f in fmts if f.get("url") and f.get("itag") in _AUDIO_PREF]
    audios.sort(key=lambda f: _AUDIO_PREF[f["itag"]])
    a = audios[0] if audios else None
    codec = re.search(r'codecs="([^".]+)', v.get("mimeType", ""))
    note = " ".join(x for x in (v.get("qualityLabel"), codec.group(1) if codec else None) if x)
    return Media(title=det.get("title") or "YouTube",
                 author=det.get("author") or "",
                 duration_s=float(det.get("lengthSeconds") or 0),
                 video_url=v["url"], video_note=note or "picture",
                 audio_url=a["url"] if a else None,
                 audio_bytes=int(a["contentLength"]) if a and a.get("contentLength") else None,
                 headers={"User-Agent": UA})


if __name__ == "__main__":
    m = resolve(sys.argv[1] if len(sys.argv) > 1 else "https://youtu.be/dQw4w9WgXcQ")
    print(f"{m.title!r} by {m.author!r}, {m.duration_s:.0f} s, picture {m.video_note}, "
          f"sound {'%.1f MB' % (m.audio_bytes / 1e6) if m.audio_bytes else 'none'}")
    print("video:", m.video_url[:90] + "...")
