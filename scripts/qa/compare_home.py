#!/usr/bin/env python3
"""Compose native Tessera captures into reproducible before/after PNG pairs.

Screenshots are uniformly scaled by the same factor within each pair. Nothing
inside either screenshot is cropped, retouched, recoloured, or overlaid.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from io import BytesIO
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


@dataclass(frozen=True)
class Feature:
    unit: str
    title: str
    capture: str


FEATURES = {
    "navigation": Feature("A01", "App shell & navigation", "classic-live.png"),
    "room": Feature("A03", "Room home", "room-live.png"),
    "ipod": Feature("A04", "iPod home", "ipod-live.png"),
    "controls": Feature("A06", "Face picker & control center", "controls/room-live.png"),
    "colour": Feature("A07", "Brightness & colour controls", "lamp/room-live.png"),
}
BACKGROUND = "#0B0A09"
INK = "#EAE4D8"
SECONDARY = "#AAA390"
ACCENT = "#E8B04B"


def fingerprint(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_font(root: Path, name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(root / "tessera/Tessera/Fonts" / name), size=size)


def compose(root: Path, before: Path, after: Path, output: Path,
            feature: Feature, screen_width: int) -> dict:
    """Preserve source pixels apart from one shared, proportional resize."""
    before = before.resolve(strict=True)
    after = after.resolve(strict=True)
    if output.resolve() in {before, after}:
        raise ValueError("The output must not overwrite a source screenshot")
    before_bytes, after_bytes = before.read_bytes(), after.read_bytes()
    with Image.open(BytesIO(before_bytes)) as source_before, Image.open(BytesIO(after_bytes)) as source_after:
        source_sizes = [source_before.size, source_after.size]
        # A different source size remains visibly different; both screenshots
        # still receive exactly the same scale rather than independent fitting.
        scale = min(1.0, screen_width / max(size[0] for size in source_sizes))
        screens = [source.convert("RGB").resize(
            (max(1, round(source.width * scale)), max(1, round(source.height * scale))),
            Image.Resampling.LANCZOS,
        ) for source in (source_before, source_after)]
    margin, gap, heading_height = 22, 20, 104
    column_width = max(screen.width for screen in screens)
    canvas_width = margin * 2 + column_width * 2 + gap
    canvas_height = heading_height + max(screen.height for screen in screens) + margin
    canvas = Image.new("RGB", (canvas_width, canvas_height), BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    eyebrow = load_font(root, "MartianMono-Regular.ttf", 10)
    label = load_font(root, "MartianMono-Medium.ttf", 11)
    title_size = 26
    title = f"{feature.unit}  {feature.title}"
    title_font = load_font(root, "Switzer-Semibold.otf", title_size)
    while draw.textlength(title, font=title_font) > canvas_width - margin * 2 and title_size > 14:
        title_size -= 1
        title_font = load_font(root, "Switzer-Semibold.otf", title_size)
    draw.text((margin, 16), "TESSERA / DESIGN PASSES", fill=SECONDARY, font=eyebrow)
    draw.text((margin, 36), title, fill=INK, font=title_font)
    placements = []
    for index, (screen, caption) in enumerate(zip(screens, ("BEFORE", "AFTER"))):
        column_x = margin + index * (column_width + gap)
        image_x = column_x + (column_width - screen.width) // 2
        draw.text((column_x, 82), caption, fill=SECONDARY if index == 0 else ACCENT, font=label)
        canvas.paste(screen, (image_x, heading_height))
        placements.append({"x": image_x, "y": heading_height, "width": screen.width, "height": screen.height})
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output, format="PNG", optimize=True)
    return {
        "unit": feature.unit,
        "title": feature.title,
        "before": str(before),
        "after": str(after),
        "before_sha256": hashlib.sha256(before_bytes).hexdigest(),
        "after_sha256": hashlib.sha256(after_bytes).hexdigest(),
        "source_sizes": source_sizes,
        "shared_scale": scale,
        "placements": placements,
        "output": str(output.resolve()),
        "output_size": list(canvas.size),
        "output_sha256": fingerprint(output),
    }


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    default_batch = root / "qa/batch-02"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before", type=Path, default=default_batch / "before")
    parser.add_argument("--after", type=Path, default=default_batch / "after")
    parser.add_argument("--output", type=Path, default=default_batch / "comparisons")
    parser.add_argument("--screen-width", type=int, default=390,
                        help="Maximum rendered screen width in pixels; default 390")
    parser.add_argument("--features", nargs="+", choices=tuple(FEATURES), default=list(FEATURES))
    args = parser.parse_args()
    if not 200 <= args.screen_width <= 1206:
        parser.error("--screen-width must be between 200 and 1206 pixels")
    selected = list(dict.fromkeys(args.features))
    missing = [str(directory / FEATURES[name].capture) for name in selected
               for directory in (args.before, args.after)
               if not (directory / FEATURES[name].capture).is_file()]
    if missing:
        parser.error("Missing native capture(s): " + ", ".join(missing))
    comparisons = []
    for name in selected:
        feature = FEATURES[name]
        result = compose(root, args.before / feature.capture, args.after / feature.capture,
                         args.output / f"{feature.unit.lower()}-{name}.png", feature, args.screen_width)
        comparisons.append(result)
        print(result["output"])
    manifest = {
        "source_files_modified": False,
        "processing": "Uniform Lanczos downscale with identical scale within each pair; no cropping or overlays inside screens.",
        "comparisons": comparisons,
    }
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
