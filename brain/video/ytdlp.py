"""yt-dlp, for the videos the wall's own resolver cannot get.

The fast path in youtube.py asks YouTube's player endpoint directly and is
answered in about a second. Some videos, so far big label releases, refuse
it: every client identity serves the first megabyte and then 403s, because
YouTube now wants a signed-in "proof of origin" token on those. Chasing
that is a full-time job, and yt-dlp is the project that does it.

So yt-dlp is the fallback, not the road: it runs only when the fast path
fails, in its own process at nice 10, and it does the downloading itself
(it knows the retries, the ranges and the tokens). What comes back is two
small files on the wall's RAM disk, which is what the player wanted anyway.

Installed by pi/install-ytdlp.sh into the brain's venv. No JavaScript
runtime is installed: the client yt-dlp reaches these videos with needs no
player script, so deno's 80 MB and V8's appetite stay off a 1 GB board.
If a video ever needs one, yt-dlp says so and this reports it.
"""
from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys

from . import Media, ResolveError

# The picture: the smallest there is, H.264 first. The sound: AAC in mp4,
# which the phone plays as it is. Slashes are preferences, and yt-dlp is
# asked for both in one run.
VIDEO_FMT = "160/278/394/133/242/395/134/18/worst[height<=360]"
# Both files sit in the wall's RAM disk while the video is on, and the wall
# has a gigabyte in total, so a long video takes the small sound stream
# (50 kbps rather than 130), the same rule the fast path uses.
AUDIO_FMT = "140/139/bestaudio[ext=m4a]"
AUDIO_FMT_LONG = "139/140/bestaudio[ext=m4a]"
LONG_S = 20 * 60
MAX_FILESIZE = "60M"
TIMEOUT = 300.0


def binary() -> str | None:
    """The yt-dlp next to the brain's own python, or one on the PATH."""
    near = os.path.join(os.path.dirname(sys.executable), "yt-dlp")
    if os.path.isfile(near) and os.access(near, os.X_OK):
        return near
    return shutil.which("yt-dlp")


def available() -> bool:
    return binary() is not None


def version() -> str | None:
    exe = binary()
    if not exe:
        return None
    try:
        return subprocess.run([exe, "--version"], capture_output=True, text=True,
                              timeout=30).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def _run(args, timeout):
    exe = binary()
    if not exe:
        raise ResolveError("yt-dlp is not installed on the wall")
    cmd = [exe, "--no-playlist", "--no-warnings", "--no-progress",
           "--no-part", "--retries", "3", "--socket-timeout", "20"] + args
    if shutil.which("nice"):
        cmd = ["nice", "-n", "10"] + cmd
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        raise ResolveError("yt-dlp took too long") from exc
    except OSError as exc:
        raise ResolveError(f"yt-dlp would not start: {exc}") from exc


def _why(out) -> str:
    """The last line yt-dlp said, cleaned up enough to show someone."""
    for line in reversed((out.stderr or "").strip().splitlines()):
        line = line.strip()
        if line.startswith("ERROR:"):
            line = line[6:].strip()
        if line and "Traceback" not in line:
            return line[:160]
    return "yt-dlp could not read that link"


def _landed(workdir: str, stem: str) -> str | None:
    """What the run actually wrote. yt-dlp prints its details BEFORE the
    file is finished, so its own path list comes back empty; the name is
    ours and the directory is ours, so the file is simply looked up."""
    found = [f for f in glob.glob(os.path.join(workdir, stem + ".*"))
             if os.path.isfile(f) and os.path.getsize(f) > 0]
    return max(found, key=os.path.getmtime) if found else None


def _clear(workdir: str, stem: str):
    for f in glob.glob(os.path.join(workdir, stem + ".*")):
        try:
            os.remove(f)
        except OSError:
            pass


def resolve(url: str, workdir: str, timeout: float = TIMEOUT) -> Media:
    """Two files on disk and what they are. Raises ResolveError with what
    yt-dlp said when it cannot."""
    os.makedirs(workdir, exist_ok=True)
    _clear(workdir, "ytdlp-picture")
    _clear(workdir, "ytdlp-sound")

    # the picture, and the video's details in the same run
    out = _run(["-f", VIDEO_FMT, "--max-filesize", MAX_FILESIZE,
                "--print-json", "--no-simulate",
                "-o", os.path.join(workdir, "ytdlp-picture.%(ext)s"), url], timeout)
    path = _landed(workdir, "ytdlp-picture")
    if out.returncode != 0 or path is None:
        _clear(workdir, "ytdlp-picture")
        # --max-filesize skips rather than fails, so say which it was
        if "larger than max-filesize" in (out.stdout or "") + (out.stderr or ""):
            raise ResolveError("that video is too big for the wall to keep")
        raise ResolveError(_why(out))
    info = {}
    for line in (out.stdout or "").splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                info = json.loads(line)
                break
            except json.JSONDecodeError:
                continue

    # the sound, if the video has any
    duration = float(info.get("duration") or 0)
    snd_out = _run(["-f", AUDIO_FMT_LONG if duration > LONG_S else AUDIO_FMT,
                    "--max-filesize", MAX_FILESIZE, "--no-simulate",
                    "-o", os.path.join(workdir, "ytdlp-sound.%(ext)s"), url], timeout)
    audio = _landed(workdir, "ytdlp-sound")
    if audio is None:
        _clear(workdir, "ytdlp-sound")
        print("[ytdlp] no sound for this one: " + _why(snd_out))

    note = " ".join(str(x) for x in (info.get("format_note") or info.get("resolution"),
                                     (info.get("vcodec") or "").split(".")[0])
                    if x and x != "none") or "picture"
    return Media(title=info.get("title") or "YouTube",
                 author=info.get("uploader") or info.get("channel") or "",
                 duration_s=duration,
                 video_url=path, video_note=note,
                 video_bytes=os.path.getsize(path),
                 audio_url=audio,
                 audio_bytes=os.path.getsize(audio) if audio else None,
                 headers={}, local=True)


if __name__ == "__main__":
    import tempfile
    where = tempfile.mkdtemp(prefix="ytdlp-test-")
    m = resolve(sys.argv[1] if len(sys.argv) > 1 else "https://youtu.be/dQw4w9WgXcQ", where)
    print(f"{m.title!r} by {m.author!r}, {m.duration_s:.0f} s, {m.video_note}")
    print(f"picture {m.video_url} ({(m.video_bytes or 0)/1e6:.2f} MB)")
    print(f"sound   {m.audio_url} ({(m.audio_bytes or 0)/1e6:.2f} MB)")
