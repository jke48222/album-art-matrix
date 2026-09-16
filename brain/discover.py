"""Show a sleeve or begin a video from a plain-language search.

Sleeve search uses Apple's public catalogue and returns automatically after
ten minutes. Video search asks the existing yt-dlp installation for one
YouTube watch URL, then hands that URL to the existing player. Both actions
run in the HTTP request worker rather than the render loop and respect their
feature switch at the moment they act.
"""
import json
import shutil
import subprocess

from .catalog import search


def show(ctrl, query, catalogue=search):
    if not ctrl.features.enabled("show"):
        return {"problem": "Show is off for this build.", "shown": False}
    results = catalogue(query, 1)
    if not results:
        ctrl.show_answer("nothing found")
        return {"problem": "Nothing matched that search.", "shown": True}
    ctrl.show_result(results, 600)
    return {**{k: results[0][k] for k in ("title", "artist", "album", "art_url")},
            "shown": True}


def play(ctrl, query):
    if not ctrl.features.enabled("show"):
        return {"problem": "Show is off for this build.", "started": False}
    if not isinstance(query, str) or not query.strip() or len(query) > 200:
        raise ValueError("query must contain 1 to 200 characters")
    binary = shutil.which("yt-dlp")
    if not binary:
        raise RuntimeError("yt-dlp is not installed")
    result = subprocess.run([binary, "--no-playlist", "--skip-download", "--dump-single-json",
                             "ytsearch1:" + query.strip()], capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError("video search failed")
    data = json.loads(result.stdout)
    video_id = data.get("id")
    if not video_id:
        raise RuntimeError("video search returned no result")
    url = "https://www.youtube.com/watch?v=" + video_id
    why = ctrl.video_start(url, sound=True, loop=False, title=data.get("title"))
    if why:
        raise RuntimeError(why)
    return {"started": True, "title": data.get("title"), "url": url}
