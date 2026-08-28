"""Album art -> LED-ready pixels (research 19, art pipeline steps 1-5).

The order is deliberate:
  Lanczos downscale + light unsharp   (box filtering turns album art to mud)
  -> sRGB decode (gamma 2.2) to linear light
  -> per-channel white balance IN LINEAR   (HUB75 primaries are green/blue-
     biased; skipping this is why almost all LED-matrix art looks cyan.
     Default gains are the research's typical values — MEASURE yours,
     see scripts/WB-PROCEDURE.md)
  -> re-encode gamma 2.2 to 8-bit.

The renderer runs with -g 2.2 so the bitslip6 library decodes back to linear
for 64-bit BCM and applies temporal dither (steps 5's "built into the
library"). Handing it encoded 8-bit keeps shadow precision through the pipe.
"""
import numpy as np
from PIL import Image, ImageFilter


def prepare(img: Image.Image, size: int,
            unsharp_radius: float = 1.0, unsharp_percent: int = 60) -> Image.Image:
    """Steps 1-2: downscale with Lanczos, then a light unsharp mask."""
    img = img.convert("RGB").resize((size, size), Image.LANCZOS)
    if unsharp_percent > 0:
        img = img.filter(ImageFilter.UnsharpMask(
            radius=unsharp_radius, percent=int(unsharp_percent), threshold=2))
    return img


def white_balance(img: Image.Image, gains) -> np.ndarray:
    """Steps 3-5: linear decode, per-channel gains, re-encode. uint8 HxWx3."""
    arr = np.asarray(img, dtype=np.float32) / 255.0
    linear = np.power(arr, 2.2)
    linear *= np.asarray(gains, dtype=np.float32)[None, None, :]
    np.clip(linear, 0.0, 1.0, out=linear)
    encoded = np.power(linear, 1.0 / 2.2) * 255.0
    return (encoded + 0.5).astype(np.uint8)


def process(img: Image.Image, size: int, gains,
            unsharp_radius: float = 1.0, unsharp_percent: int = 60):
    """Returns (pre_wb: PIL.Image for previews, panel_rgb888: bytes for the wall)."""
    pre = prepare(img, size, unsharp_radius, unsharp_percent)
    balanced = white_balance(pre, gains)
    return pre, balanced.tobytes()


def apply_finish(img: Image.Image, finish: str) -> Image.Image:
    """Optional rendering finish on the prepared sleeve (control "finish").

    clean  — the pipeline as-is
    dither — 16-color Floyd-Steinberg; deliberate retro grain at 64px
    poster — 3 bits/channel posterization; flat print-like fields
    """
    if finish == "dither":
        return img.quantize(colors=16,
                            dither=Image.Dither.FLOYDSTEINBERG).convert("RGB")
    if finish == "poster":
        from PIL import ImageOps
        return ImageOps.posterize(img, 3)
    return img


def dominant_colors(img: Image.Image, n: int = 2) -> list[str]:
    """The sleeve's n most-common colors as "#rrggbb", most common first.
    Feeds ambient match_art. Tiny resize first so it costs nothing."""
    small = img.convert("RGB").resize((24, 24), Image.LANCZOS)
    pal = small.quantize(colors=max(8, n * 4))
    counts = sorted(pal.getcolors(), reverse=True)
    palette = pal.getpalette()

    # Rank by population WEIGHTED BY SATURATION. A photographic sleeve is
    # mostly near-grey skin, paper and highlight; ranking on raw population
    # picks one of those, and "match the album" then lights the wall grey.
    scored = []
    for count, idx in counts:
        r, g, b = palette[idx * 3: idx * 3 + 3]
        mx, mn = max(r, g, b), min(r, g, b)
        if mx < 70 or mn > 232:          # too dark to light a room, or a white fill
            continue
        sat = (mx - mn) / mx if mx else 0
        if sat < 0.20:                   # not a colour to light a room with
            continue
        scored.append((count * (0.2 + sat * 0.8), r, g, b))

    scored.sort(reverse=True)
    out = [f"#{r:02x}{g:02x}{b:02x}" for _, r, g, b in scored[:n]]
    return out or ["#4060ff", "#ff2080"][:n]
