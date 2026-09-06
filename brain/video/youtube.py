"""YouTube, read the way the YouTube apps read it.

A video on the wall needs two small things: the picture at a size a 64 px
panel can use (144p is already twice too big) and the sound, as a file the
phone can play. YouTube's player endpoint hands both to its own apps, and
the iPhone and Android clients' answers come with plain stream URLs, no
signature puzzle, that download at full speed from the wall when asked for
in byte ranges (3 MB/s on 2026-09-06).

The catch, seen the same day: YouTube is rolling out a signed-in token
("proof of origin") server by server, and a stream URL that lands on such a
server answers 403 to everything. A fresh answer lands on a fresh server, so
the resolver tries a stream with one small ranged request before handing it
over, and on a refusal asks again: the other client, then the first once
more. That is the whole trick, and it is YouTube's to change; when it does,
this file changes, and yt-dlp is the fallback (VIDEO.md).

Nothing is cached and nothing is kept: the URLs expire in hours, and the
files live in RAM only while the video is on.

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

# (name, innertube client number, context, user agent), in the order tried
CLIENTS = [
    ("IOS", 5,
     {"clientName": "IOS", "clientVersion": "20.11.6", "deviceMake": "Apple",
      "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.3.2.22D82"},
     "com.google.ios.youtube/20.11.6 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)"),
    ("ANDROID", 3,
     {"clientName": "ANDROID", "clientVersion": "20.10.38", "osName": "Android",
      "osVersion": "11", "androidSdkVersion": 30},
     "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip"),
]
PROBE_BYTES = 4095

_ID = r"([0-9A-Za-z_-]{11})"
_PATTERNS = [
    re.compile(r"(?:youtube\.com|youtube-nocookie\.com)/"
               r"(?:watch\?(?:[^#]*&)?v=|embed/|shorts/|live/|v/)" + _ID),
    re.compile(r"youtu\.be/" + _ID),
]

# The picture. 240p first: cropped square it is 240 px, and the panel wants
# something to throw away when it downscales — 144p leaves a square of 144,
# barely twice the panel, and it shows. H.264 before VP9 and AV1, which the
# wall would decode in software at several times the cost.
_VIDEO_PREF = {133: 0, 134: 1, 160: 2, 242: 3, 243: 4, 278: 5, 395: 6, 396: 7, 394: 8, 18: 9}
# The sound: AAC in an mp4 container, which AVPlayer plays as it is. The
# file lives in the wall's RAM, so a long video takes the small one.
_AUDIO_PREF = {140: 0, 139: 1}          # 130 kbps, 50 kbps
_LONG_S = 20 * 60
_AUDIO_MAX = 80_000_000


def video_id(url: str) -> Optional[str]:
    """The eleven characters, from any of the link shapes YouTube uses."""
    for p in _PATTERNS:
        m = p.search((url or "").strip())
        if m:
            return m.group(1)
    return None


def _ask(num, ctx, ua, vid, timeout):
    body = {"context": {"client": {**ctx, "hl": "en", "gl": "US"}}, "videoId": vid,
            "contentCheckOk": True, "racyCheckOk": True}
    headers = {"User-Agent": ua, "X-YouTube-Client-Name": str(num),
               "X-YouTube-Client-Version": ctx["clientVersion"],
               "Origin": "https://www.youtube.com"}
    resp = requests.post(PLAYER, json=body, headers=headers, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def _choose(d: dict, det: dict, ua: str) -> Optional[Media]:
    """The two streams out of one answer, or None when it has no plain ones."""
    sd = d.get("streamingData") or {}
    fmts = (sd.get("formats") or []) + (sd.get("adaptiveFormats") or [])
    videos = [f for f in fmts if f.get("url") and f.get("itag") in _VIDEO_PREF]
    videos.sort(key=lambda f: _VIDEO_PREF[f["itag"]])
    if not videos:
        videos = [f for f in fmts if f.get("url")
                  and str(f.get("mimeType", "")).startswith("video/")
                  and (f.get("height") or 9999) <= 360]
        videos.sort(key=lambda f: (f.get("height") or 9999, f.get("bitrate") or 0))
    if not videos:
        return None
    v = videos[0]
    duration = float(det.get("lengthSeconds") or 0)
    audios = [f for f in fmts if f.get("url") and f.get("itag") in _AUDIO_PREF]
    audios.sort(key=lambda f: _AUDIO_PREF[f["itag"]], reverse=duration > _LONG_S)
    a = audios[0] if audios else None
    if a and int(a.get("contentLength") or 0) > _AUDIO_MAX:
        raise ResolveError("too long: the sound would not fit in the wall's memory")
    codec = re.search(r'codecs="([^".]+)', v.get("mimeType", ""))
    note = " ".join(x for x in (v.get("qualityLabel"), codec.group(1) if codec else None) if x)
    return Media(title=det.get("title") or "YouTube",
                 author=det.get("author") or "",
                 duration_s=duration,
                 video_url=v["url"], video_note=note or "picture",
                 video_bytes=int(v["contentLength"]) if v.get("contentLength") else None,
                 audio_url=a["url"] if a else None,
                 audio_bytes=int(a["contentLength"]) if a and a.get("contentLength") else None,
                 headers={"User-Agent": ua})


def _probe(url: str, ua: str) -> int:
    """One small ranged request: does this server serve this stream?"""
    try:
        r = requests.get(url, headers={"User-Agent": ua, "Range": f"bytes=0-{PROBE_BYTES}"},
                         timeout=10, stream=True)
        code = r.status_code
        r.close()
        return code
    except requests.RequestException:
        return 0


def resolve(url: str, timeout: float = 15.0) -> Media:
    vid = video_id(url)
    if not vid:
        raise ResolveError("not a YouTube link")
    last = None
    # each client once, then the first again: a fresh answer, a fresh server
    for name, num, ctx, ua in CLIENTS + CLIENTS[:1]:
        try:
            d = _ask(num, ctx, ua, vid, timeout)
        except (requests.RequestException, ValueError) as exc:
            last = f"YouTube did not answer: {exc}"
            continue
        ps = d.get("playabilityStatus") or {}
        status = ps.get("status")
        if status == "ERROR":
            raise ResolveError("YouTube says: " + (ps.get("reason") or "unavailable"))
        if status != "OK":
            last = "YouTube says: " + (ps.get("reason") or status or "unplayable")
            continue
        det = d.get("videoDetails") or {}
        if det.get("isLive"):
            raise ResolveError("live streams are not supported yet")
        media = _choose(d, det, ua)
        if media is None:
            last = f"no plain stream from the {name} client"
            continue
        code = _probe(media.video_url, ua)
        if code in (200, 206) and (not media.audio_url
                                   or _probe(media.audio_url, ua) in (200, 206)):
            if name != CLIENTS[0][0]:
                print(f"[youtube] served by the {name} client")
            return media
        last = f"YouTube refused the stream ({code or 'no answer'}, {name} client)"
        print(f"[youtube] {last}; asking again")
    raise ResolveError((last or "YouTube gave nothing usable")
                       + ". Some videos need a signed-in token now; try once more in a moment")


if __name__ == "__main__":
    m = resolve(sys.argv[1] if len(sys.argv) > 1 else "https://youtu.be/dQw4w9WgXcQ")
    print(f"{m.title!r} by {m.author!r}, {m.duration_s:.0f} s, picture {m.video_note} "
          f"{'%.1f MB' % (m.video_bytes / 1e6) if m.video_bytes else ''}, "
          f"sound {'%.1f MB' % (m.audio_bytes / 1e6) if m.audio_bytes else 'none'}")
