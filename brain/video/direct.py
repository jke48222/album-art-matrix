"""Any link ffmpeg can read on its own (an mp4, a webm, a mov, an HLS
playlist), and any file already on the wall (a picture the phone sent up).
ffprobe says how long it is and what it is called; sound, when wanted, is
made by ffmpeg into an m4a, since a bare file is what the phone can play.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.parse

from . import Media, ResolveError

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"


def resolve(url: str, timeout: float = 20.0) -> Media:
    url = (url or "").strip()
    local = os.path.isfile(url)
    if not local and not url.lower().startswith(("http://", "https://")):
        raise ResolveError("not a link the wall can fetch")
    if not shutil.which("ffprobe"):
        raise ResolveError("ffprobe is missing on the wall")
    cmd = ["ffprobe", "-v", "error"]
    if not local:
        cmd += ["-user_agent", UA]
    cmd += ["-show_entries", "format=duration:format_tags=title:stream=codec_type",
            "-of", "json", url]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise ResolveError("the link took too long to answer") from exc
    if out.returncode != 0:
        why = (out.stderr or "").strip().splitlines()
        raise ResolveError("ffmpeg cannot read that" + (f": {why[-1][:80]}" if why else ""))
    try:
        info = json.loads(out.stdout or "{}")
    except json.JSONDecodeError as exc:
        raise ResolveError("ffprobe gave no answer") from exc
    fmt = info.get("format") or {}
    kinds = {s.get("codec_type") for s in info.get("streams") or []}
    if "video" not in kinds:
        raise ResolveError("there is no picture in that")
    try:
        duration = float(fmt.get("duration") or 0)
    except ValueError:
        duration = 0.0
    name = os.path.basename(url) if local else \
        urllib.parse.unquote(os.path.basename(urllib.parse.urlparse(url).path))
    title = (fmt.get("tags") or {}).get("title") or name or "Video"
    return Media(title=title, author="", duration_s=duration,
                 video_url=url, video_note="picture",
                 audio_url=url if "audio" in kinds else None,
                 audio_bytes=None, audio_transcode=True,
                 headers={} if local else {"User-Agent": UA})
