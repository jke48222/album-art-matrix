"""Authored, isolated library fixtures and production puzzle renders for native QA.

These songs, artworks, collections and score records are fictional test data.
No account, external service, microphone or physical wall is used.
"""
from __future__ import annotations

import base64
import hashlib
import importlib
from io import BytesIO
import json
from pathlib import Path
import subprocess
import sys
import time

from PIL import Image, ImageDraw

PHASES = ("ready", "empty", "learning", "failed", "result")
PUZZLE = "530070000600195000098000060800060003400803001700020006060000280000419005000080079"
STAMP = 1790447400


def authored_cover(index: int, side: int = 512) -> bytes:
    palettes = [((31, 67, 71), (189, 211, 186), (230, 163, 72)),
                ((75, 54, 61), (216, 183, 166), (235, 111, 74)),
                ((31, 47, 77), (167, 189, 206), (219, 205, 170)),
                ((61, 69, 51), (192, 202, 161), (234, 200, 146)),
                ((99, 58, 47), (226, 198, 164), (138, 161, 171)),
                ((58, 51, 72), (192, 174, 197), (222, 166, 134))]
    dark, light, accent = palettes[index % len(palettes)]
    image = Image.new("RGB", (side, side), light)
    draw = ImageDraw.Draw(image)
    if index % 3 == 0:
        draw.ellipse((side*.40, side*.13, side*.84, side*.57), fill=accent)
        draw.polygon([(0,side*.7),(side*.28,side*.48),(side*.61,side*.78),(side,side*.58),(side,side),(0,side)], fill=dark)
        for y in range(int(side*.81), side, 15): draw.line((0,y,side,y-36), fill=accent, width=2)
    elif index % 3 == 1:
        for inset in range(16, 235, 18):
            draw.rounded_rectangle((inset,inset,side-inset,side-inset),radius=side*.30,outline=dark,width=7)
        draw.rectangle((side*.48,0,side*.55,side),fill=accent)
    else:
        draw.rectangle((0,0,side*.32,side),fill=dark)
        draw.ellipse((side*.15,side*.19,side*.83,side*.87),fill=accent)
        for y in range(0,side,16): draw.line((side*.4,y,side,y+side*.24),fill=dark,width=2)
    buffer = BytesIO(); image.save(buffer, "PNG")
    return buffer.getvalue()


def render_game(renderer_root: Path, feature: str, phase: str) -> dict:
    command = [sys.executable, str(Path(__file__).resolve()), "--render", str(renderer_root.resolve()), feature, phase]
    result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=60)
    return json.loads(result.stdout)


def configure(wall, host: str, phase: str, feature: str, renderer_root: Path | None = None) -> None:
    from brain import tuning
    root = renderer_root or Path(__file__).resolve().parents[2]
    titles = ["Into the Quiet", "Amber Hours", "Blue Distance", "Slow Sun", "After the Rain", "Paper Moon"]
    artists = ["The Tessera Sessions", "Mira Vale", "North Coast", "Mira Vale", "The Tessera Sessions", "Lena June"]
    albums = ["After the Rain", "Amber Hours", "Blue Distance", "Slow Sun", "After the Rain", "Paper Moon"]
    songs, releases, assets = [], [], []
    for index, (title, artist, album) in enumerate(zip(titles, artists, albums)):
        route = f"/qa-library-cover-{index}.png"
        raw = authored_cover(index)
        wall.covers[route] = raw
        url = f"http://{host}{route}"
        assets.append({"path": route, "sha256": hashlib.sha256(raw).hexdigest(), "authored_fixture": True})
        songs.append({"id": f"qa-song-{index}", "title": title, "artist": artist, "album": album,
                      "how": ["preview", "ear"] if index == 0 else ["told"] if index % 2 else ["ear"],
                      "added": STAMP-index*86400, "matched": [24,12,7,4,3,1][index],
                      "last_matched": STAMP-index*2100, "landmarks": [1239,987,1460,1192,901,1381][index], "art_url": url})
        releases.append({"release_id": 900100+index, "title": album, "artists": [artist], "year": 2026-index,
                         "label": "Tessera Sessions", "catno": f"TS-{index+1:03}", "formats": ["Vinyl", "LP"],
                         "descriptions": ["Album", "Limited Edition"] if index == 0 else ["Album"],
                         "cover": url, "country": "US", "url": f"https://www.discogs.com/release/{900100+index}",
                         "plays": [24,12,7,4,3,1][index], "added": f"2026-09-{25-index:02}T08:00:00-04:00", "copies": 2 if index == 0 else 1})
    empty = phase == "empty"
    teacher = {"by_ear": True, "learning": "Amber Hours by Mira Vale" if phase == "learning" else None,
               "problem": "The preview catalogue isn't answering. Your library is safe." if phase == "failed" else None,
               "last_learned": {"id": "qa-song-0", "title": titles[0], "artist": artists[0], "at": STAMP} if phase == "result" else None}
    wall.studies["/teach"] = {"enabled": True, "landmarks": sum(s["landmarks"] for s in songs) if not empty else 0,
                              "min_score": 15, "songs": [] if empty else songs, "teacher": teacher,
                              "last_match": None if empty else {"id":"qa-song-0", "title":titles[0], "artist":artists[0], "score":44, "at":STAMP}, "problem": None}
    shelf = {"releases": [] if empty else releases, "user": "tessera_room", "token_set": not empty,
             "synced_at": time.time()-1200, "syncing": phase == "learning", "sync_id": "qa-shelf-sync" if phase == "learning" else None,
             "completed_sync_id": "qa-shelf-done", "problem": "Discogs couldn't finish reading the collection. Your saved records are still here." if phase == "failed" else None}
    wall.studies["/shelf"] = shelf
    wall.studies["/services"] = {"ears": True, "discogs": {k: v for k,v in shelf.items() if k != "releases"} | {"releases":len(shelf["releases"])}}
    specs = getattr(tuning,"KNOBS",getattr(tuning,"SPECS",[]))
    keys = ["name","group","kind","min","max","step","restart","note"]
    knobs = [dict(zip(keys,k)) for k in specs if k[0] in {"teach","teach_by_ear","teach_match_score"}]
    values = {"teach":True,"teach_by_ear":True,"teach_match_score":15}
    wall.studies["/tuning"] = {"knobs":knobs,"values":values,"defaults":dict(values)}
    game_data = render_game(root, "sudoku" if feature == "sudoku" else "wordle", phase)
    wall.studies["/game/list"] = {"games": game_data["list"]}
    wall.studies["/game"] = game_data["status"]
    if feature in {"games", "wordle", "sudoku"} and not empty:
        wall.capture_frame = base64.b64decode(game_data["frame"])
    wall.library_game_fixture = {"feature": feature, "phase": phase, "renderer_root": str(root.resolve()),
                                 "authored_assets": assets, "payloads": {k:v for k,v in wall.studies.items() if k in {"/teach","/shelf","/services","/tuning","/game/list","/game"}}}


def respond(wall, path: str, body: dict):
    """Optional isolated acknowledgements. These never leave the QA server."""
    if path == "/tuning":
        wall.studies[path]["values"].update({k:v for k,v in body.items() if k in wall.studies[path]["values"]})
        return 200, wall.studies[path]
    if path == "/teach/learn":
        song = next((s for s in wall.studies["/teach"]["songs"] if s["title"] == body.get("title")), None)
        return (200, {"learnt":song}) if song else (404,{"error":"This capture fixture has no preview for that song."})
    if path == "/teach/forget":
        songs = wall.studies["/teach"]["songs"]
        matched = any(song["id"] == body.get("id") for song in songs)
        wall.studies["/teach"]["songs"] = [song for song in songs if song["id"] != body.get("id")]
        return (200 if matched else 404), {"forgot": matched}
    if path == "/shelf/sync":
        return 200, {"accepted": True, "sync_id": "qa-shelf-done"}
    if path.startswith("/game/"):
        return 200, wall.studies["/game"]
    return None


def _render(root: Path, feature: str, phase: str) -> dict:
    sys.path.insert(0, str(root.resolve()))
    from brain.games import GAMES
    for name in ("wordle","sudoku","connections","spellingbee","letterboxed","strands","crossword","contexto","heardle","quiz","pictures","pictionary","twentyq","reaction","whistlebird","arcade"):
        importlib.import_module(f"brain.games.{name}")
    cls = GAMES[feature]
    game = cls(None, {"word":"crane"} if feature == "wordle" else {"puzzle":PUZZLE}, ["You"])
    game.setup()
    if feature == "wordle":
        for guess in ("slate", "trace"):
            game.apply({"guess":guess}, "You")
        if phase == "result": game.apply({"guess":"crane"}, "You")
        game.revealed_at = time.monotonic()-10
    else:
        blanks = [i for i,v in enumerate(game.puzzle) if not v]
        for cell in (blanks if phase == "result" else blanks[:2]):
            game.apply({"cell":cell,"digit":game.solution[cell]}, "You")
        if phase != "result": game.apply({"choose":blanks[2]}, "You")
    game.started = STAMP-420
    game.finished = STAMP if game.over else None
    game.changed_at = time.monotonic()-10
    state = game.public()
    # Added protocol fields keep old and current apps on identical meaningful data.
    if feature == "sudoku":
        state.setdefault("notes", {})
        state.setdefault("can_undo", True)
        state.setdefault("remaining", state.get("left",0)+len(state.get("wrong",[])))
        state.setdefault("filled_by_you", 2 if phase != "result" else 51)
    status = {"running":phase != "empty","seq":42,"session_id":"qa-game-001","on_wall":phase != "empty",
              "starting":feature if phase == "learning" else None,
              "game":state if phase != "empty" else None,
              "scores":{"You":{"played":12,"won":9,"streak":3,"best":5}},"voice_words":["crane","trace","slate"],
              "error":"The move couldn't be saved. Try again." if phase == "failed" else None}
    frame = game.frame_at(64, 8)
    raw = frame.tobytes()
    return {"status":status,"list":[game_cls.describe() for game_cls in GAMES.values()],"frame":base64.b64encode(raw).decode()}


if __name__ == "__main__":
    if len(sys.argv) != 5 or sys.argv[1] != "--render":
        raise SystemExit("Usage: library_games_fixtures.py --render CHECKOUT wordle|sudoku PHASE")
    print(json.dumps(_render(Path(sys.argv[2]), sys.argv[3], sys.argv[4])))
