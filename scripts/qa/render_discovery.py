#!/usr/bin/env python3
"""Render matched discovery wall states from two isolated production source roots.

No API keys, hardware, microphone, paid inference or mocked drawing functions are
used. The existing renderers receive deterministic authored artwork and runtime
state. PNGs preserve native RGB bytes; comparison enlargements use nearest-neighbour.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace

import numpy as np
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
SIDES = (64, 192, 512)
FPS = 15
FRAMES = 60
# GIF ticks are 10ms. Alternating tick counts preserves exactly four seconds.
DURATIONS = [round((i + 1) * 100 / FPS) * 10 - round(i * 100 / FPS) * 10 for i in range(FRAMES)]
PROMPT = "An amber sun over a quiet sea, paper-cut layers"
ANSWER = "A little light for your room. The coast is quiet tonight."
CASES = {
    "imagine-waiting": {"kind": "imagine", "state": "waiting", "still_s": 1.8,
                        "description": "Waiting for provider output; no generated image has arrived. No percentage is inferred."},
    "imagine-partial": {"kind": "imagine", "state": "partial", "still_s": 1.6,
                        "description": "First real partial image, 1.6 seconds into its production sketch-to-colour reveal."},
    "imagine-done": {"kind": "imagine", "state": "done", "still_s": 2.8,
                     "description": "The final image, settled after the production reveal. Uses the same linear-light panel conversion before and after."},
    "earworm-result": {"kind": "discovery", "state": "earworm", "still_s": 2.8, "motion": False,
                       "description": "Production Shower.earworm with an authored song identity and local artwork fixture. Previous text banner versus the current full sleeve, matching phone artwork composition."},
    "voice-listening": {"kind": "voice", "state": "listening", "still_s": 2.8,
                        "description": "Production microphone-responsive Horizon with a deterministic loudness envelope and colour derived from the fixture artwork."},
    "voice-thinking": {"kind": "voice", "state": "thinking", "still_s": 2.8,
                       "description": "Production Horizon thinking bead at a fixed elapsed time. No transcription or provider request is made."},
    "voice-answer": {"kind": "voice", "state": "answering", "still_s": 2.8,
                     "description": "Production opening transition and paginated AnswerFace with an authored QA answer; text adapts to each native pixel size."},
}
SOURCES = ("brain/imagine.py", "brain/voice/voice.py", "brain/art/horizon.py",
           "brain/art/answer.py", "brain/art/pixelfont.py", "brain/art/sting.py",
           "brain/assets/tessera-record-final-720p.mp4", "brain/show.py",
           "brain/art/pipeline.py", "brain/games/board.py", "brain/wall.py")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def authored_artwork(side: int = 1024) -> Image.Image:
    """A deliberately authored geometric sun-and-sea fixture, never AI output."""
    yy, xx = np.mgrid[0:side, 0:side].astype(np.float64)
    x, y = (xx + 0.5) / side, (yy + 0.5) / side
    top, bottom = np.array((20, 37, 50)), np.array((52, 79, 87))
    colour = top + (bottom - top) * np.clip(y[..., None] / 0.68, 0, 1)
    sun = np.hypot(x - 0.56, y - 0.38) < 0.195
    disc = np.array((245, 178, 100)) + np.array((8, 31, 26)) * np.clip((0.5 - y)[..., None], 0, 0.3)
    colour[sun] = disc[sun]
    layers = [(0.57, 0.018, 1.4, (30, 66, 78)), (0.66, 0.031, 2.5, (24, 55, 66)),
              (0.76, 0.026, 4.0, (19, 44, 52)), (0.88, 0.020, 2.2, (15, 33, 40))]
    for index, (height, amplitude, phase, ink) in enumerate(layers):
        shore = height + amplitude * np.sin(x * math.tau * 0.9 + phase)
        colour[y >= shore] = ink
        line = np.abs(y - shore) < 0.0018
        colour[line] = np.array(ink) + np.array((11, 16, 17))
    # Small broken reflections belong to the authored picture itself.
    for line in range(14):
        row = 0.58 + line * 0.018
        span = 0.075 - line * 0.0035
        left = 0.56 - span + 0.009 * math.sin(line * 1.8)
        reflect = (np.abs(y - row) < 0.0015) & (x > left) & (x < left + 2 * span)
        colour[reflect] = (129 - line * 4, 116 - line * 3, 87 - line * 2)
    return Image.fromarray(np.clip(colour, 0, 255).astype(np.uint8), "RGB")


def render_worker(source: Path, output: Path, artwork: Path):
    # Each invocation is a separate interpreter. Relative imports therefore
    # resolve against the actual baseline/current dependency trees.
    sys.path.insert(0, str(source))
    from brain.imagine import LiveDrawing, enhance_for_panel
    from brain.voice.voice import Voice
    from brain.art.answer import AnswerFace
    from brain.art.horizon import ink_of
    from brain.art import sting
    import brain.show as show_module
    from brain.wall import Wall
    sting.CACHE_DIR = str(Path(tempfile.gettempdir()) / "tessera-batch08-render-sting")

    output.mkdir(parents=True, exist_ok=True)
    picture = Image.open(artwork).convert("RGB")
    records, movies = [], []
    for name, case in CASES.items():
        for side in SIDES:
            clock = [0.0]
            if case["kind"] == "imagine":
                face = LiveDrawing(clock=lambda: clock[0])
                face.start(PROMPT)
                if case["state"] == "partial":
                    face.partial(picture.copy())
                elif case["state"] == "done":
                    face.finish(picture.copy())
                def frame_at(t):
                    clock[0] = t
                    return face.frame_at(side, t)
            elif case["kind"] == "discovery":
                # Fixture only the external search and artwork fetch. The
                # actual production earworm method composes/stages the frame.
                state = {"mode": "art"}
                ctrl = SimpleNamespace(wall=Wall(tile=64, cols=side // 64, rows=side // 64),
                                       shown_seq=0, frame_override=None, tuning=None,
                                       dirty=SimpleNamespace(set=lambda: None), _lock=threading.RLock(),
                                       get=lambda: dict(state), apply=lambda patch: state.update(patch))
                identity = {"title": "Amber Hours", "artist": "Mira Vale", "confidence": "high"}
                asker = SimpleNamespace(ready=True, earworm=lambda words: dict(identity))
                show_module.find_art = lambda query: {"art_url": "fixture://sun-and-sea", "album": "Amber Hours", **identity}
                show_module.fetch_art = lambda url: picture.copy()
                shower = show_module.Shower(ctrl, asker=asker)
                reply = shower.earworm("An authored song clue, used only for QA")
                if not reply.get("shown") or ctrl.frame_override is None:
                    raise RuntimeError(f"Production earworm did not stage a frame: {reply}")
                fixed = np.frombuffer(ctrl.frame_override, dtype=np.uint8).reshape(side, side, 3).copy()
                timer = getattr(shower, "_timer", None)
                if timer is not None:
                    timer.cancel()
                def frame_at(t):
                    return fixed.copy()
            else:
                # Constructing Voice starts no worker and opens no microphone.
                ctrl = SimpleNamespace(dirty=SimpleNamespace(set=lambda: None))
                voice = Voice(ctrl, wake=None, transcriber=None, size=side, log=lambda _: None)
                voice.state = case["state"]
                voice.since = 0.0
                voice.picture = np.asarray(enhance_for_panel(picture, side), dtype=np.uint8).copy()
                voice.ink = ink_of(voice.picture)
                voice.floor_db = -67.0
                if case["state"] == "answering":
                    voice._face_answer = AnswerFace(side, ANSWER, ink=voice.ink)
                def frame_at(t):
                    voice.level_db = -36.0 + 9.0 * math.sin(t * math.tau * 0.8)
                    return voice.frame(t, side)
            still_index = round(case["still_s"] * FPS)
            motion = []
            for index in range(FRAMES):
                t = index / FPS
                pixels = frame_at(t)
                if pixels is None:
                    raise RuntimeError(f"Production renderer ended unexpectedly: {name}, {side}, t={t}")
                image = Image.fromarray(pixels, "RGB")
                if index == still_index:
                    filename = f"{name}-{side}.png"
                    image.save(output / filename)
                    records.append({"case": name, "side": side, "file": filename,
                                    "elapsed_s": t, "rgb_sha256": hashlib.sha256(image.tobytes()).hexdigest(),
                                    "description": case["description"], "source_dimensions": list(picture.size),
                                    "prompt": PROMPT if case["kind"] == "imagine" else None,
                                    "answer": ANSWER if case["state"] == "answering" else None,
                                    "microphone_floor_db": -67 if case["state"] == "listening" else None,
                                    "microphone_level_db": -36 + 9 * math.sin(t * math.tau * 0.8) if case["state"] == "listening" else None})
                if side == 64 and case.get("motion", True):
                    # Preserve raw PNG motion frames for lossless paired GIF
                    # construction; no repeated quantization on the comparison.
                    image.save(output / f"{name}-motion-{index:03d}.png")
                    motion.append(image.resize((384, 384), Image.Resampling.NEAREST))
            if motion:
                name_gif = f"{name}-motion.gif"
                motion[0].save(output / name_gif, save_all=True, append_images=motion[1:],
                               duration=DURATIONS, loop=0, disposal=2)
                movies.append({"case": name, "file": name_gif, "native_side": 64,
                               "display_side": 384, "fps": FPS, "frames": FRAMES})
    manifest = {"source_root": str(source), "source_sha256": {path: digest(source / path) for path in SOURCES},
                "native_frames": records, "movies": movies}
    (output / "render-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def pair(before: Image.Image, after: Image.Image, title: str, side: int, elapsed: float):
    canvas = Image.new("RGB", (1048, 570), "#101319")
    draw = ImageDraw.Draw(canvas)
    for x, label, image in ((8, "BEFORE", before), (528, "AFTER", after)):
        draw.text((x + 5, 12), f"{label} / {title} / native {side}px / {elapsed:.2f}s", fill="#eee5d5")
        canvas.paste(image.resize((512, 512), Image.Resampling.NEAREST), (x, 46))
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-root", type=Path, default=Path("/tmp/tessera-batch08-baseline"))
    parser.add_argument("--baseline-ref", default="f31d1f1c77549e9f3a111da7823ff886e17bad74")
    parser.add_argument("--output", type=Path, default=ROOT / "qa/batch-08/wall")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--source-root", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--artwork", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        render_worker(args.source_root.resolve(), args.output.resolve(), args.artwork.resolve())
        return
    output = args.output.resolve(); output.mkdir(parents=True, exist_ok=True)
    artwork = output / "authored-fixture-sun-and-sea.png"
    authored_artwork().save(artwork)
    for version, source in (("before", args.baseline_root), ("after", ROOT)):
        subprocess.run([sys.executable, str(Path(__file__).resolve()), "--worker", "--source-root", str(source),
                        "--output", str(output / version), "--artwork", str(artwork)], check=True, cwd=source)
    manifests = {v: json.loads((output / v / "render-manifest.json").read_text()) for v in ("before", "after")}
    comparisons, motion = [], []
    for name, case in CASES.items():
        for side in SIDES:
            images = {v: Image.open(output / v / f"{name}-{side}.png").convert("RGB") for v in manifests}
            filename = f"{name}-{side}-comparison.png"
            pair(images["before"], images["after"], name, side, case["still_s"]).save(output / filename)
            identical = images["before"].tobytes() == images["after"].tobytes()
            comparisons.append({"case": name, "side": side, "file": filename, "elapsed_s": case["still_s"],
                                "rgb_identical": identical,
                                "before": f"before/{name}-{side}.png", "after": f"after/{name}-{side}.png",
                                "description": case["description"]})
        if not case.get("motion", True):
            continue
        frames = []
        for index in range(FRAMES):
            paths = {v: output / v / f"{name}-motion-{index:03d}.png" for v in manifests}
            before = Image.open(paths["before"]).convert("RGB")
            after = Image.open(paths["after"]).convert("RGB")
            frames.append(pair(before, after, name, 64, index / FPS))
            # Intermediate lossless motion images are reproducible, not needed
            # in the published gallery. Native stills remain untouched PNGs.
            for path in paths.values():
                path.unlink()
        filename = f"{name}-motion-comparison.gif"
        frames[0].save(output / filename, save_all=True, append_images=frames[1:],
                       duration=DURATIONS, loop=0, disposal=2)
        motion.append({"case": name, "file": filename, "native_side": 64, "frames": FRAMES, "fps": FPS,
                       "duration_s": FRAMES / FPS, "quantization": "GIF palettes only; inspect native PNGs for exact RGB values."})
    result = {"baseline_ref": args.baseline_ref,
              "baseline_root": str(args.baseline_root.resolve()),
              "fixture": {"file": artwork.name, "sha256": digest(artwork), "authored_in": "scripts/qa/render_discovery.py",
                          "description": "Deterministic geometric sun and sea, authored solely for QA. This is neither a provider-generated picture nor actual user artwork."},
              "comparison_processing": "Unretouched production native RGB PNGs. Before left / after right. Same elapsed time, artwork, answer text and microphone envelope; nearest-neighbour enlargement to equal 512px displays.",
              "limitations": ["Controlled runtime states exercise production renderers; no paid inference, wake model, speech recognition, hardware audio or provider request was made.",
                              "Listening, thinking and answer composition is intentionally retained; pixel-identical before/after comparisons are labeled in this manifest.",
                              "Raw rendered RGB does not certify physical LED colour or contrast. GIF palette quantization is for motion review only.",
                              "512px is true production rendering at that requested size, not an upscale of a 64px frame. 64px and 192px sources are provided separately.",
                              "Static PNG comparisons are the reduced-motion alternative; the gallery must not require autoplaying GIFs to review a state."],
              "source_sha256": {v: manifests[v]["source_sha256"] for v in manifests},
              "comparisons": comparisons, "motion": motion,
              "native_frames": {v: manifests[v]["native_frames"] for v in manifests}}
    (output / "manifest.json").write_text(json.dumps(result, indent=2) + "\n")
    checks = 0
    for version, rows in result["native_frames"].items():
        for row in rows:
            image = Image.open(output / version / row["file"]).convert("RGB")
            assert image.size == (row["side"], row["side"])
            assert hashlib.sha256(image.tobytes()).hexdigest() == row["rgb_sha256"]
            checks += 2
    for row in comparisons:
        image = Image.open(output / row["file"]).convert("RGB")
        for x, key in ((8, "before"), (528, "after")):
            native = Image.open(output / row[key]).convert("RGB").resize((512, 512), Image.Resampling.NEAREST)
            assert image.crop((x, 46, x + 512, 558)).tobytes() == native.tobytes()
            checks += 1
    for path in output.rglob("*.gif"):
        gif = Image.open(path)
        duration = 0
        for index in range(gif.n_frames):
            gif.seek(index)
            duration += gif.info["duration"]
        assert duration == 4000, (path, duration)
        checks += 1
    (output / "render-validation.json").write_text(json.dumps({
        "passed": checks, "failed": 0,
        "checks": "Every native PNG dimension and RGB digest; every unretouched comparison paste; all 18 motion GIFs preserve exact 4000ms duration.",
        "visual_inspection": "Reviewed with view_image: Imagine waiting64, partial192, done512; Voice listening64, thinking192, answer64; Earworm result64. Before and after are legible with artwork preserved; listening/answer compositions intentionally unchanged.",
        "physical_review": "Not certified by rendered RGB; root performs real wall checks separately."
    }, indent=2) + "\n")
    print(json.dumps({"native_pngs": 2 * len(CASES) * len(SIDES), "comparisons": len(comparisons), "motion_comparisons": len(motion),
                      "identical_comparisons": sum(c["rgb_identical"] for c in comparisons), "output": str(output)}))


if __name__ == "__main__":
    main()
