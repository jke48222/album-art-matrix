#!/usr/bin/env python3
"""Reproducible wall weather comparison: actual LEDs and detailed composition."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PIL import Image, ImageDraw, ImageFont
from brain.art.weather import WeatherFace, FONTS

out = Path(__file__).resolve().parents[1] / "qa" / "weather"
data = dict(temp=22.8, high=24.4, low=17.2, code=3, is_day=False, wind_kmh=8)
now = 1790116560
width = 432
sheet = Image.new("RGB", (width * 3, width + 70), (12, 17, 23))
draw = ImageDraw.Draw(sheet)
font = ImageFont.truetype(str(FONTS / "Switzer-Medium.otf"), 17)
for i, (size, title) in enumerate(((64, "64 × 64 · actual wall pixels"),
                                 (192, "192 × 192 · larger wall"),
                                 (512, "Full-resolution composition"))):
    frame = Image.fromarray(WeatherFace(size).frame_at(25, data, place="Douglasville, Georgia", now=now))
    frame.save(out / f"parity-{size}.png")
    draw.text((i * width + 22, 23), title, font=font, fill=(238, 235, 226))
    sheet.paste(frame.resize((width, width), Image.Resampling.NEAREST if size < 512 else Image.Resampling.LANCZOS),
                (i * width, 70))
sheet.save(out / "weather-parity.jpg", quality=93)
print(out / "weather-parity.jpg")
