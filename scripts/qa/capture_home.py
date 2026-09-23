#!/usr/bin/env python3
"""Capture the real Tessera home screens against an isolated loopback wall."""
from __future__ import annotations

import argparse
import base64
import copy
import io
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import subprocess
import sys
import threading
import time
from unittest.mock import patch
from urllib.parse import urlsplit
from urllib.request import urlopen

from PIL import Image


DEFAULT_STATES = (
    "classic-live", "classic-paused", "classic-offline", "classic-off",
    "classic-empty", "classic-long", "classic-large", "room-live", "ipod-live",
)
SAFE_STATE_KEYS = (
    "mode", "brightness", "rpm", "effect", "finish", "match_art", "color",
    "color2", "clock_24h", "weather_units", "place", "now_showing", "progress",
    "art_colors", "shown_seq", "wall",
)


def command(*args: str, capture: bool = False) -> str:
    result = subprocess.run(args, check=True, text=True, capture_output=True, timeout=90)
    return result.stdout.strip() if capture else ""


def artwork(side: int = 64) -> bytes:
    """A deterministic print-like fixture; never installed in the product."""
    pixels = bytearray()
    for y in range(side):
        for x in range(side):
            u, v = x / side, y / side
            distance = math.hypot(u - 0.66, v - 0.33)
            ripple = math.sin(u * 15 + v * 9) * 3
            if distance < 0.235:
                rgb = (229 + ripple, 151 + ripple, 65 + ripple)
            elif v > 0.62 + 0.10 * math.sin(u * 6.8):
                rgb = (17 + ripple, 49 + ripple, 59 + ripple)
            elif v > 0.49 + 0.055 * math.sin(u * 9 + 1):
                rgb = (33 + ripple, 80 + ripple, 89 + ripple)
            else:
                rgb = (184 - 42 * v + ripple, 206 - 40 * v + ripple, 196 - 30 * v + ripple)
            pixels.extend(max(0, min(255, round(channel))) for channel in rgb)
    return bytes(pixels)


def fixture(variant: str) -> dict:
    state = {
        "mode": "art", "brightness": 1.0, "rpm": 7.5, "effect": "solid",
        "finish": "clean", "match_art": False, "color": "#e5a343",
        "color2": "#215059", "art_colors": ["#e5a343", "#215059", "#b8cec4"],
        "now_showing": {"title": "Into the Quiet", "artist": "The Tessera Sessions",
                        "album": "After the Rain"},
        "progress": {"at": 93000.0, "of": 245000.0, "playing": variant != "paused"},
        "shown_seq": 420,
        "wall": {"width": 64, "height": 64, "tile": 64, "cols": 1, "rows": 1, "frame_side": 64},
    }
    if variant in {"long", "large"}:
        state["now_showing"] = {
            "title": "Everything Is Beautiful When We Listen Together",
            "artist": "The Metropolitan Orchestra & the Voices of Tomorrow",
            "album": "A Collection of Songs for the Long Way Home — Deluxe Edition",
        }
    if variant in {"empty", "off"}:
        state["now_showing"] = {}
        state["progress"] = {}
    if variant == "off":
        state["mode"] = "off"
    return state


class FixtureWall:
    def __init__(self) -> None:
        self.state = fixture("live")
        self.frame = artwork()
        self.available = True
        self.requests: list[dict] = []
        self.lock = threading.Lock()
        self.journal = []
        self.covers = {}
        self.shelf = []
        self.lyrics = {"state": "done", "lines": [
            {"at": 0, "text": "the room is full of light", "words": []},
            {"at": 90, "text": "a little colour in the quiet", "words": [{"at":90,"text":"a little"},{"at":92,"text":"colour"},{"at":96,"text":"in the quiet"}]},
            {"at": 110, "text": "we leave the window open", "words": []}]}
        self.studies = {}

    def load(self, state: dict, frame: bytes) -> None:
        with self.lock:
            self.state = copy.deepcopy(state)
            self.frame = frame
            self.available = True
            self.requests = []


def make_handler(wall: FixtureWall) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args: object) -> None:
            pass

        def response(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def do_GET(self) -> None:
            path = urlsplit(self.path).path
            with wall.lock:
                wall.requests.append({"method": "GET", "path": path})
                available, state, frame = wall.available, copy.deepcopy(wall.state), wall.frame
            if not available:
                self.response(503, b"Fixture connection unavailable", "text/plain")
                return
            if path == "/frame.raw":
                self.response(200, frame, "application/octet-stream")
                return
            if path in wall.covers:
                self.response(200, wall.covers[path], "image/png")
                return
            if path in {"/finishes", "/ambient/previews"}:
                payload = wall.studies.get(path, {})
                self.response(200, json.dumps(payload).encode(), "application/json")
                return
            if path == "/lyrics":
                payload = wall.lyrics if state.get("now_showing") else {"state":"idle","lines":[]}
                self.response(200, json.dumps(payload).encode(), "application/json")
                return
            payload = (state if path == "/state" else {"entries": wall.journal} if path == "/journal"
                       else {"releases": wall.shelf} if path == "/shelf" else {})
            self.response(200, json.dumps(payload).encode(), "application/json")

        def do_POST(self) -> None:
            length = min(int(self.headers.get("Content-Length", "0")), 4 * 1024 * 1024)
            data = self.rfile.read(length)
            path = urlsplit(self.path).path
            with wall.lock:
                wall.requests.append({"method": "POST", "path": path})
            if path == "/routines/preview":
                from brain.art.text_modes import Clock, Countdown
                payload = json.loads(data)
                size = math.isqrt(len(wall.frame) // 3)
                if payload.get("face") == "timer":
                    image = Countdown(size).frame_at(payload.get("remaining_s",600), payload.get("total_s",600))
                else:
                    with patch("brain.art.text_modes.time.localtime", return_value=time.struct_time((2026,9,23,7,30,24,2,266,1))):
                        image = Clock(size, twenty_four=payload.get("twenty_four", True)).frame_at(0)
                self.response(200,json.dumps({"px":base64.b64encode(image.tobytes()).decode(),"side":size}).encode(),"application/json")
                return
            if path == "/ticker/preview":
                from brain.art.text_modes import Ticker, Crawl
                payload = json.loads(data)
                size = math.isqrt(len(wall.frame) // 3)
                args = dict(color=payload.get("color", "#f4f1ea"), speed=payload.get("speed",1), colors=payload.get("colors",[]), loop=False)
                style = payload.get("style", "across")
                renderer = Ticker(size,payload["text"],**args) if style == "across" else Crawl(size,payload["text"],tilt=style == "tilt",**args)
                travel = renderer.width + size + 4*max(1,size//64) if style == "across" else renderer.h+renderer.span+8*max(1,size//64)
                t = payload.get("phase",.35)*travel/renderer.px_per_s
                encoded = base64.b64encode(renderer.frame_at(t).tobytes()).decode()
                self.response(200,json.dumps({"px":encoded}).encode(),"application/json")
                return
            # Acknowledge only inside this fixture. Never forward writes anywhere.
            self.response(200, b"{}", "application/json")

    return Handler


def wall_snapshot(host: str, output: Path) -> tuple[dict, bytes]:
    if "/" in host or "@" in host or not host:
        raise ValueError("--wall-host must contain only a hostname and optional port")
    base = f"http://{host}"
    with urlopen(f"{base}/state", timeout=8) as response:
        source = json.load(response)
    with urlopen(f"{base}/frame.raw", timeout=8) as response:
        frame = response.read(512 * 512 * 3 + 1)
    side = math.isqrt(len(frame) // 3)
    if not 16 <= side <= 512 or side * side * 3 != len(frame):
        raise ValueError("The wall did not return a square RGB888 frame")
    state = {key: source[key] for key in SAFE_STATE_KEYS if key in source}
    # Only identity/display fields are persisted; service and account configuration is excluded.
    if "now_showing" in state:
        state["now_showing"] = {key: value for key, value in state["now_showing"].items()
                                if key in {"title", "artist", "album"}}
    if "progress" in state:
        state["progress"] = {key: value for key, value in state["progress"].items()
                             if key in {"at", "of", "playing", "stamped"}}
    (output / "wall-state.json").write_text(json.dumps(state, indent=2) + "\n")
    Image.frombytes("RGB", (side, side), frame).save(output / "wall-source.png")
    return state, frame


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Optional simulator .app to install before capture")
    parser.add_argument("--simulator", default="9108AFCE-E437-42FF-A946-C41349BE6540")
    parser.add_argument("--bundle", default="com.jalenedusei.tessera")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--states", nargs="+", default=list(DEFAULT_STATES),
                        help="Any of classic-live/paused/offline/off/empty/long/large, room-live, ipod-live, classic-wall")
    parser.add_argument("--wall-host", help="Read-only capture of this real wall; adds classic-wall to the run")
    parser.add_argument("--settle", type=float, default=5.0)
    parser.add_argument("--launch-argument", action="append", default=[],
                        help="Extra app argument, for example --launch-argument=-controls")
    parser.add_argument("--mode", choices=("art", "cd", "ambient", "weather", "clock", "timer", "off", "game", "video", "frame", "lyrics", "nine", "ticker"))
    parser.add_argument("--routine-state", choices=("idle", "active", "complete", "ringing", "location"))
    parser.add_argument("--renderer-root", type=Path, help="Production renderer checkout for matched baseline captures")
    parser.add_argument("--brightness", type=float)
    parser.add_argument("--journal", choices=("empty", "recent"), default="empty")
    args = parser.parse_args()
    valid = set(DEFAULT_STATES) | {"classic-wall", "room-paused", "ipod-paused", "room-offline", "ipod-offline",
                                 "room-long", "ipod-long", "room-large", "ipod-large"}
    if any(state not in valid for state in args.states):
        parser.error("Unknown state; choose from: " + ", ".join(sorted(valid)))
    if "classic-wall" in args.states and not args.wall_host:
        parser.error("classic-wall requires --wall-host")
    if not math.isfinite(args.settle) or not 1 <= args.settle <= 30:
        parser.error("--settle must be between 1 and 30 seconds")
    if args.brightness is not None and (not math.isfinite(args.brightness) or not 0.05 <= args.brightness <= 1):
        parser.error("--brightness must be between 0.05 and 1")
    if args.renderer_root:
        sys.path.insert(0, str(args.renderer_root.resolve()))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / "manifest.json"
    previous_captures = {}
    if manifest_path.exists():
        prior = json.loads(manifest_path.read_text())
        previous_captures = {capture["state"]: capture for capture in prior.get("captures", [])}
    if args.app:
        command("xcrun", "simctl", "install", args.simulator, str(args.app.resolve()))
    actual = wall_snapshot(args.wall_host, output) if args.wall_host else None
    states = list(args.states)
    if actual is not None and "classic-wall" not in states:
        states.append("classic-wall")
    previous_size = command("xcrun", "simctl", "ui", args.simulator, "content_size", capture=True)
    wall = FixtureWall()
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(wall))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    fixture_host = f"127.0.0.1:{server.server_port}"
    if args.journal == "recent":
        titles = ["Into the Quiet", "Amber Hours", "Blue Distance", "Slow Sun", "After the Rain", "Paper Moon"]
        artists = ["The Tessera Sessions", "Mira Vale", "North Coast", "Mira Vale", "The Tessera Sessions", "Lena June"]
        now = int(time.time())
        for i in range(18):
            title, artist = titles[i % 6], artists[i % 6]
            route = f"/qa-cover-{i % 6}.png"
            if route not in wall.covers:
                art = Image.frombytes("RGB", (64, 64), artwork())
                if i % 6:
                    channels = art.split()
                    art = Image.merge("RGB", channels[i % 3:] + channels[:i % 3])
                    if i % 2: art = art.transpose(Image.Transpose.FLIP_LEFT_RIGHT)
                stream = io.BytesIO(); art.resize((512, 512), Image.Resampling.NEAREST).save(stream, "PNG")
                wall.covers[route] = stream.getvalue()
            wall.journal.append({"ts": now - (i // 6) * 86400 - (i % 6) * 1600,
                                 "title": title, "artist": artist, "album": "After the Rain" if i % 6 == 0 else title,
                                 "art_url": f"http://{fixture_host}{route}"})
            if i < 6:
                wall.shelf.append({"release_id": i + 1, "title": "After the Rain" if i == 0 else title,
                                   "artists": [artist], "year": 2026 - i, "label": "Tessera Sessions",
                                   "catno": f"TS-{i + 1:03}", "formats": ["Vinyl", "LP"],
                                   "cover": f"http://{fixture_host}{route}", "country": "US",
                                   "url": "https://www.discogs.com", "plays": 12 - i})
    captures = []
    try:
        for name in states:
            design, variant = name.split("-", 1)
            if variant == "wall":
                assert actual is not None
                state, frame = actual
            else:
                state, frame = fixture(variant), artwork()
                if variant in {"empty", "off"}:
                    frame = bytes(len(frame))
                if args.mode is not None:
                    state["mode"] = args.mode
                if args.brightness is not None:
                    state["brightness"] = args.brightness
                if state["mode"] == "cd":
                    sys.path.insert(0, str(args.renderer_root.resolve() if args.renderer_root else Path(__file__).resolve().parents[2]))
                    from brain.art.disc import DiscAnimator
                    disc = DiscAnimator(Image.frombytes("RGB", (64, 64), artwork()), 64)
                    frame = disc.frame_at(0, progress_s=93, fraction=93 / 245).tobytes()
            if variant != "wall":
                sys.path.insert(0, str(args.renderer_root.resolve() if args.renderer_root else Path(__file__).resolve().parents[2]))
                from brain.art.pipeline import apply_finish
                from brain.art.effects import Ambient
                from brain.art.nine import compose as compose_nine
                from brain.art.lyrics import LyricSheet, LyricCanvas
                if state["mode"] == "lyrics" and state.get("now_showing"):
                    sheet = LyricSheet([(row["at"],row["text"],[(w["at"],w["text"]) for w in row["words"]]) for row in wall.lyrics["lines"]])
                    frame = LyricCanvas(64, Image.frombytes("RGB", (64,64), artwork()), sheet).frame_at(93).tobytes()
                    state["progress"]["playing"] = False
                elif state["mode"] == "nine":
                    covers = [Image.open(io.BytesIO(data)) for data in wall.covers.values()]
                    frame = compose_nine(covers,64).tobytes()
                elif state["mode"] == "ambient":
                    state["effect"] = "gradient"
                    frame = Ambient(64,"gradient",state["color"],state["color2"],1).frame_at(8).tobytes()
                if state["mode"] in {"clock", "timer"} or args.routine_state:
                    from brain.art.text_modes import Clock, Countdown
                    now = datetime(2026,9,23,11,30,24,tzinfo=timezone.utc).timestamp()
                    state.update({"wall_time":now,"wall_timezone":"America/New_York","wall_utc_offset_s":-14400,
                        "clock_24h":True,"alarm_enabled":True,"alarm_time":"07:30","alarm_next_at":now+86400,
                        "sun":"on","sun_night":.25,"lat":33.75,"lon":-84.75,"place":"Douglasville, Georgia",
                        "sun_phase":"day","sun_factor":1.,"sunrise_at":now-600,"sunset_at":now+42480,
                        "effective_brightness":1.,"sleep_state":"idle","wake_enabled":True,"wake_time":"07:00",
                        "wake_fade_min":20.,"wake_next_at":now+84576,"wake_next_end_at":now+85776})
                    if args.routine_state == "active":
                        state.update({"sleep_state":"fading","sleep_total_s":1800,"sleep_remaining_s":1242,
                            "sleep_ends_at":now+1242,"effective_brightness":.63,"wake_active":True,"wake_progress":.35})
                    elif args.routine_state == "complete":
                        state.update({"sleep_state":"completed","sleep_total_s":1800,"effective_brightness":0.})
                    elif args.routine_state == "location":
                        state.update({"sun_phase":"location","lat":999,"lon":999,"place":""})
                        state.pop("sunrise_at",None);state.pop("sunset_at",None)
                    if state["mode"] == "timer":
                        remaining = 0 if args.routine_state == "ringing" else 462
                        state.update({"timer_remaining_s":remaining,"timer_total_s":600,"timer_ends_at":now+remaining,
                            "timer_state":"ringing" if remaining == 0 else "counting","timer_ringing":remaining==0,"timer_kind":"countdown"})
                        frame=Countdown(64).frame_at(remaining,600).tobytes()
                    elif state["mode"] == "clock":
                        with patch("brain.art.text_modes.time.localtime", return_value=time.struct_time((2026,9,23,7,30,24,2,266,1))):
                            frame=Clock(64).frame_at(0).tobytes()
                base = Image.frombytes("RGB", (64,64), frame)
                wall.studies["/finishes"] = {name:base64.b64encode(apply_finish(base,name).tobytes()).decode() for name in ("clean","dither","poster")}
                wall.studies["/ambient/previews"] = {name:base64.b64encode(Ambient(64,name,state["color"],state["color2"],1).frame_at(8).tobytes()).decode() for name in ("solid","breathe","pulse","rainbow","gradient","plaid","weave","deco","snake")}
            wall.load(state, frame)
            command("xcrun", "simctl", "ui", args.simulator, "content_size",
                    "accessibility-extra-extra-extra-large" if variant == "large" else "large")
            command("xcrun", "simctl", "launch", "--terminate-running-process", args.simulator,
                    args.bundle, "-nointro", "-onboarded", "YES", "-intro.sting.migrated", "YES",
                    "-intro.style", "none", "-design", design, "-wall.host", fixture_host,
                    "-reporter.host", "", "-reporter.background", "NO", "-live.enabled", "NO",
                    *args.launch_argument)
            time.sleep(args.settle)
            if variant == "offline":
                with wall.lock:
                    wall.available = False
                time.sleep(max(4, args.settle))
            image_path = output / f"{name}.png"
            command("xcrun", "simctl", "io", args.simulator, "screenshot", str(image_path))
            side = math.isqrt(len(frame) // 3)
            Image.frombytes("RGB", (side, side), frame).save(output / f"{name}-frame.png")
            with wall.lock:
                reads = len([request for request in wall.requests if request == {"method": "GET", "path": "/state"}])
                writes = [request for request in wall.requests if request["method"] == "POST"]
            if reads == 0:
                raise RuntimeError(f"{name}: app never reached the fixture /state endpoint")
            captures.append({"state": name, "image": image_path.name, "frame": f"{name}-frame.png",
                             "mode": state["mode"], "state_reads": reads, "fixture_writes": writes,
                             "app": str(args.app) if args.app else None,
                             "launch_arguments": args.launch_argument,
                             "captured_at": datetime.now(timezone.utc).isoformat(),
                             "dynamic_type": "AX5" if variant == "large" else "large"})
            print(image_path, flush=True)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        if previous_size not in {"unknown", "unsupported"}:
            command("xcrun", "simctl", "ui", args.simulator, "content_size", previous_size)
        previous_captures.update({capture["state"]: capture for capture in captures})
        manifest = {"captured_at": datetime.now(timezone.utc).isoformat(), "simulator": args.simulator,
                    "bundle": args.bundle, "app": str(args.app) if args.app else None,
                    "fixture_only": True, "captures": list(previous_captures.values()),
                    "interaction_scope": "Rendering and network-state transitions; no simulated touches"}
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
