#!/usr/bin/env python3
"""Capture the real Tessera home screens against an isolated loopback wall."""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import subprocess
import threading
import time
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
            payload = state if path == "/state" else {"entries": []} if path == "/journal" else {}
            self.response(200, json.dumps(payload).encode(), "application/json")

        def do_POST(self) -> None:
            length = min(int(self.headers.get("Content-Length", "0")), 4 * 1024 * 1024)
            self.rfile.read(length)
            with wall.lock:
                wall.requests.append({"method": "POST", "path": urlsplit(self.path).path})
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
    parser.add_argument("--brightness", type=float)
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
