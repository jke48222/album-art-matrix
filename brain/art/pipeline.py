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
from functools import lru_cache

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


BLACK_POINT = 12.0       # sRGB byte value at and below which a pixel is off
# The panel holds a level steadily from about a quarter of the way up; below
# that the renderer's temporal dither turns a dim field into LEDs blinking in
# and out. Anything dimmer than FLOOR, but not black, is lifted to FLOOR with
# its colour kept, so a dim grey reads as a dim grey.
NOISE = 16.0             # below this a pixel is a photograph's noise: off
FLOOR = 64.0             # the lowest level the panel is steady at


@lru_cache(maxsize=8)
def _wb_lut(gains: tuple) -> np.ndarray:
    """3x256 uint8 table for white_balance. The mapping depends only on the
    input byte and that channel's gain (the same float32 ops on the same
    values, so bit-identical to the direct formula) — and this runs per frame
    at animation rate on a Pi, where two full-array pow() calls were most of
    the frame budget."""
    # A black point first. A photo's "black" is noise, values of one to a
    # dozen, invisible on a screen; the renderer decodes them to linear and
    # dithers them in time, and each becomes an LED that flashes now and
    # then, red or green by whichever channel the noise favoured. Below the
    # point is off; above it, the range is stretched back to white.
    byte = np.arange(256, dtype=np.float32)
    v = np.clip((byte - BLACK_POINT) / (255.0 - BLACK_POINT), 0.0, 1.0)
    # the dark-end lean, by the channel's own level (see LOW_END)
    t = np.clip((LOW_END - byte) / (LOW_END - LOW_FULL), 0.0, 1.0)
    lean = np.stack([1.0 + (LOW_RED - 1.0) * t,
                     np.ones_like(t),
                     1.0 + (LOW_BLUE - 1.0) * t]).astype(np.float32)
    linear = np.power(v, 2.2)[None, :] \
        * np.asarray(gains, dtype=np.float32)[:, None] * lean
    np.clip(linear, 0.0, 1.0, out=linear)
    encoded = np.power(linear, 1.0 / 2.2) * 255.0
    return (encoded + 0.5).astype(np.uint8)


# Pictures: the panel's dark end. See steady(). A cut at 40 was tried and
# took the rocks and the shadow side of a figure clean off the wall; the
# lift keeps them, compressed but in order.
PIC_BLACK = 16      # below this, a photograph's noise: off
PIC_FLOOR = 64      # the dimmest a lit picture pixel is drawn at (the black
                    # point below takes it to about 52 as sent: two of the
                    # panel's 64 steps at the current cap)
PIC_KNEE = 104      # from here up, as drawn

# The panel's colour at the dark end. Its LEDs sit on short drive windows,
# and a red LED reaches full current far sooner in a window than a blue one
# (its forward voltage is lowest, blue's highest), so a dim pixel of any
# hue leans red and loses blue: pink skin on a dark sleeve came out orange.
# Below LOW_END the balance leans the other way to meet it, fully by
# LOW_FULL. Two numbers to tune by eye, from a photo of the wall.
LOW_END = 160.0
LOW_FULL = 40.0
LOW_RED = 0.93      # red gain at the dark end, relative (0.85 read orange-free but blue)
LOW_BLUE = 1.15     # blue gain at the dark end, relative (1.35 was overly blue)


def steady(arr: np.ndarray, hard: bool = False, floor: bool = True) -> np.ndarray:
    """Dim tones raised to where the panel can hold them. See FLOOR.

    Three shapes. `hard` lifts every dim tone to FLOOR outright: right for a
    design, where a dim grey is a flat tone drawn on purpose. The default is
    a curve, sqrt-shaped, that raises the dark end while keeping its order:
    a sleeve's shadows stay shadows instead of becoming one grey, which is
    what the hard lift did to nearly half the pixels of a dark cover.

    `floor=False` lifts nothing, and only takes the noise off. That is for
    moving pictures. A night scene lives almost entirely between 16 and 104,
    which the curve squeezes into 64 to 104: on the wall it came out as a
    flat grey field with the street lights barely above it. A sleeve is
    still and its shadows must survive the panel's dither; a video moves,
    which hides the dither, and what it cannot survive is losing its
    blacks.
    """
    a = arr.astype(np.float32)
    peak = a.max(axis=2, keepdims=True)
    safe = np.maximum(peak, 1.0)
    if not floor:
        return np.where(peak < PIC_BLACK, 0.0, a).astype(np.uint8)
    if hard:
        lift = np.where(peak < NOISE, 0.0,
                        np.where(peak < FLOOR, FLOOR / safe, 1.0))
    else:
        # Pictures. The panel has only a few steps at the dark end, so the
        # shadows are lifted into the steps it has, in order: 16 -> 64,
        # 44 -> 77, 72 -> 89, 104 -> 104, then as is. Noise below 16 is off.
        knee = PIC_KNEE
        wanted = np.where(peak < PIC_BLACK, 0.0,
                          np.where(peak < knee,
                                   PIC_FLOOR + (safe - PIC_BLACK)
                                   * (knee - PIC_FLOOR) / (knee - PIC_BLACK),
                                   safe))
        lift = wanted / safe
    return np.clip(a * lift, 0, 255).astype(np.uint8)


def white_balance(img: Image.Image, gains, hard: bool = False,
                  floor: bool = True) -> np.ndarray:
    """Steps 3-5: dim tones lifted, linear decode, per-channel gains,
    re-encode. uint8 HxWx3. Everything the wall lights comes through here,
    so this is where the panel's own floor belongs. `floor=False` keeps the
    blacks black, which is what a moving picture needs (see steady)."""
    lut = _wb_lut((float(gains[0]), float(gains[1]), float(gains[2])))
    arr = steady(np.asarray(img), hard=hard, floor=floor)
    out = np.empty_like(arr)
    for c in range(3):
        out[..., c] = lut[c][arr[..., c]]
    return out


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
        src = np.asarray(img.convert("RGB"))
        out = np.asarray(img.quantize(colors=16,
                                      dither=Image.Dither.FLOYDSTEINBERG).convert("RGB")).copy()
        # the palette rarely holds a true black, so error diffusion sprinkles
        # its colours across black fields: off pixels lit red and green at
        # random. What was black stays off.
        out[src.max(axis=2) < 12] = 0
        return Image.fromarray(out)
    if finish == "poster":
        from PIL import ImageOps
        return ImageOps.posterize(img, 3)
    return img


def dominant_colors(img: Image.Image, n: int = 2) -> list[str]:
    """The colours a picture would lend a room, the most telling first.

    Not the most common ones. A photograph is mostly skin, paper, grass in
    shade and highlight, and ranking on population lights the wall grey,
    which is exactly what the wall was doing: a cover whose brightest
    colour is a warm tan lit the room in two near-neutral greys, because
    the picture was first averaged down to 24 px and quantised to eight
    tones, and nothing that survived that carried enough colour to pass.

    So the picture is read at 48 px, every lit pixel is weighed by how much
    colour it carries, and the hues are gathered into bins. A hue that
    covers a small part of the picture strongly (a jacket, a neon sign, a
    sky) beats a large wash of nearly-grey. What comes back is that hue's
    own colour, brought up to a level that lights a room but keeping the
    saturation it had. Only a picture with no colour at all falls back to
    its own grey.
    """
    small = img.convert("RGB").resize((48, 48), Image.LANCZOS)
    arr = np.asarray(small, dtype=np.float32).reshape(-1, 3)
    mx = arr.max(axis=1)
    mn = arr.min(axis=1)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1.0), 0.0)
    # too dark to light anything, or a paper-white fill with no colour in it
    lit = (mx >= 56) & (mn <= 240)
    hue = _hue(arr, mx, mn)
    # Colour carried, not area covered: squared, so a small strong patch
    # outweighs a wide faint one, which is how a person reads a picture.
    weight = np.where(lit, sat ** 2, 0.0)

    out: list[str] = []
    if weight.sum() > 0:
        bins = np.clip((hue / 15.0).astype(np.int32), 0, 23)   # 24 bins of 15 degrees
        mass = np.bincount(bins, weights=weight, minlength=24)
        # a hue's neighbours belong with it: a red at 359 and one at 1 are one colour
        spread = mass + 0.5 * (np.roll(mass, 1) + np.roll(mass, -1))
        for _ in range(n):
            best = int(np.argmax(spread))
            if spread[best] <= 0:
                break
            near = (np.abs((bins - best + 12) % 24 - 12) <= 1) & lit
            if not near.any():
                spread[best] = 0.0
                continue
            w = weight[near][:, None]
            colour = (arr[near] * w).sum(axis=0) / max(float(w.sum()), 1e-6)
            out.append(_as_light(colour))
            for d in range(-2, 3):                    # this hue is spoken for
                spread[(best + d) % 24] = 0.0

    if not out:
        # A black-and-white sleeve has no colour to lend. Its own tone is the
        # honest answer: the mean of what is lit, brought up to a light.
        pale = arr[mx >= 40]
        if len(pale):
            out = [_as_light(pale.mean(axis=0))]
    while out and len(out) < n:
        r, g, b = (int(out[0][i:i + 2], 16) for i in (1, 3, 5))
        out.append("#%02x%02x%02x" % (int(r * 0.72), int(g * 0.72), int(b * 0.72)))
    return (out or ["#d8d8d8", "#9a9a9a"])[:n]


def _hue(arr: np.ndarray, mx: np.ndarray, mn: np.ndarray) -> np.ndarray:
    """Hue in degrees, 0-360, for an Nx3 array."""
    r, g, b = arr[:, 0], arr[:, 1], arr[:, 2]
    span = np.maximum(mx - mn, 1e-6)
    h = np.where(mx == r, (g - b) / span % 6.0,
                 np.where(mx == g, (b - r) / span + 2.0, (r - g) / span + 4.0))
    return (h * 60.0) % 360.0


def _as_light(colour) -> str:
    """A colour brought up to something that lights a room, keeping its own
    hue and saturation."""
    r, g, b = (float(c) for c in colour)
    top = max(r, g, b, 1.0)
    k = 232.0 / top if top < 232.0 else 1.0
    return "#%02x%02x%02x" % tuple(min(255, int(c * k + 0.5)) for c in (r, g, b))
