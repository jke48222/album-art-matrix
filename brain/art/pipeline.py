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


# Every shaping step below is OFF by default (2026-09-15): what the wall is
# fed is the preview, pixel for pixel, with only the white-balance gains
# between the two. The lift, the black point and the dark-end lean stay in
# the code and on the tuning page, their tuned values kept in the comments,
# for anyone who wants them back.
BLACK_POINT = 0.0        # sRGB byte at and below which a pixel is off (was 12)
# The panel holds a level steadily from about a quarter of the way up; below
# that the renderer's temporal dither turns a dim field into LEDs blinking in
# and out. Anything dimmer than FLOOR, but not black, is lifted to FLOOR with
# its colour kept, so a dim grey reads as a dim grey. Both at 0, the hard
# lift is the identity.
NOISE = 0.0              # below this a pixel is a photograph's noise: off (was 16)
FLOOR = 0.0              # the lowest level the panel is steady at (was 64)


@lru_cache(maxsize=32)
def _wb_lut(gains: tuple, shape: tuple) -> np.ndarray:
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
    black, low_end, low_full, low_red, low_blue = shape
    byte = np.arange(256, dtype=np.float32)
    v = np.clip((byte - black) / (255.0 - black), 0.0, 1.0)
    # the dark-end lean, by the channel's own level (see LOW_END)
    t = np.clip((low_end - byte) / max(low_end - low_full, 1e-6), 0.0, 1.0)
    lean = np.stack([1.0 + (low_red - 1.0) * t,
                     np.ones_like(t),
                     1.0 + (low_blue - 1.0) * t]).astype(np.float32)
    linear = np.power(v, 2.2)[None, :] \
        * np.asarray(gains, dtype=np.float32)[:, None] * lean
    np.clip(linear, 0.0, 1.0, out=linear)
    encoded = np.power(linear, 1.0 / 2.2) * 255.0
    return (encoded + 0.5).astype(np.uint8)


# Pictures: the panel's dark end. See steady(). A cut at 40 was tried and
# took the rocks and the shadow side of a figure clean off the wall; the
# lift keeps them, compressed but in order.
PIC_BLACK = 0       # below this, a photograph's noise: off (was 16)
PIC_FLOOR = 0       # the dimmest a lit picture pixel is drawn at (was 64: the
                    # black point below took it to about 52 as sent, two of
                    # the panel's 64 steps at the current cap). At 0, with
                    # PIC_BLACK 0, the picture curve is the identity.
PIC_KNEE = 104      # from here up, as drawn

# The panel's colour at the dark end. Its LEDs sit on short drive windows,
# and a red LED reaches full current far sooner in a window than a blue one
# (its forward voltage is lowest, blue's highest), so a dim pixel of any
# hue leans red and loses blue: pink skin on a dark sleeve came out orange.
# Below LOW_END the balance leans the other way to meet it, fully by
# LOW_FULL. Two numbers to tune by eye, from a photo of the wall.
LOW_END = 160.0
LOW_FULL = 40.0
LOW_RED = 1.0       # red gain at the dark end, relative; 1.0 is no lean. Was
                    # tuned to 0.93 (0.85 read orange-free but blue).
LOW_BLUE = 1.0      # blue gain at the dark end, relative; 1.0 is no lean. Was
                    # tuned to 1.15 (1.35 was overly blue).


# The panel's own steps. The renderer decodes each byte it is sent (x^2.2),
# scales it by the panel's brightness cap, truncates that to a byte and rounds
# the byte to one of BIT_DEPTH lit slots (rpi-gpu-hub75-matrix, tone_map_rgb_bits
# and byte_to_bcm64). At a cap of 140 that is 35 slots, and the first one
# needs sRGB 37: below a few slots the three channels drop out one at a time,
# so a dark brown lights as one slot of red and nothing else, and a dark
# picture is a field of single primaries. NEAREST_COLOUR picks, for every
# pixel that wants fewer than NEAR_MAX slots, the slot triple whose colour
# is nearest (CIELAB) to what was wanted, and sends the bytes that land on
# exactly those slots. Black beats a lone red; a dim grey beats a lone blue.
NEAREST_COLOUR = True
PANEL_CAP = 160          # the renderer's -b; the brain writes it every pass
BIT_DEPTH = 64           # the renderer's -d
NEAR_MAX = 8             # pixels wanting fewer slots than this are searched


def _srgb_to_linear(b) -> np.ndarray:
    return np.power(np.asarray(b, dtype=np.float64) / 255.0, 2.2)


_XYZ = np.array([[0.4124, 0.3576, 0.1805],
                 [0.2126, 0.7152, 0.0722],
                 [0.0193, 0.1192, 0.9505]])
_WHITE = np.array([0.95047, 1.0, 1.08883])


def _lab(lin: np.ndarray) -> np.ndarray:
    """linear sRGB (..., 3) -> CIELAB, D65."""
    xyz = lin @ _XYZ.T / _WHITE
    f = np.where(xyz > 0.008856, np.cbrt(np.maximum(xyz, 0.0)),
                 7.787 * xyz + 16.0 / 116.0)
    return np.stack([116.0 * f[..., 1] - 16.0,
                     500.0 * (f[..., 0] - f[..., 1]),
                     200.0 * (f[..., 1] - f[..., 2])], axis=-1)


@lru_cache(maxsize=8)
def _panel_tables(cap: int, depth: int):
    """For one cap: the slots every byte lands on, the byte to send for each
    slot count (the middle of its run, so the renderer's temporal dither,
    which nudges a byte by one, cannot knock it off), and the Lab colour of
    every slot triple up to NEAR_MAX."""
    v = np.arange(256)
    byte = np.floor(_srgb_to_linear(v) * cap).astype(np.int64)
    slots = (byte * depth + 127) // 255
    top = int(slots.max())
    send = np.zeros(top + 1, dtype=np.uint8)
    for n in range(1, top + 1):
        run = np.nonzero(slots == n)[0]
        send[n] = run[len(run) // 2]
    m = min(NEAR_MAX, top) + 1
    grid = np.stack(np.meshgrid(np.arange(m), np.arange(m), np.arange(m),
                                indexing="ij"), axis=-1).reshape(-1, 3)
    return slots, send, top, m, _lab(grid / float(depth))


def nearest_colour(out: np.ndarray, cap: int, depth: int) -> np.ndarray:
    """out: uint8 HxWx3 as it would be sent. Dark pixels are replaced by the
    bytes that light the nearest slot triple; the rest are left alone, since
    above NEAR_MAX slots the panel's own rounding is within half a slot."""
    cap = max(1, min(254, int(cap)))
    slots, send, top, m, lab_grid = _panel_tables(cap, int(depth))
    flat = out.reshape(-1, 3)
    want = _srgb_to_linear(flat) * (cap / 255.0)            # light wanted, of full
    ideal = want * depth                                     # in slots
    dark = np.nonzero(ideal.max(axis=1) < (m - 1))[0]
    if dark.size == 0:
        return out
    uniq, inv = np.unique(flat[dark], axis=0, return_inverse=True)
    uw = _srgb_to_linear(uniq) * (cap / 255.0)
    target = _lab(uw)
    lo = np.floor(uw * depth).astype(np.int64)
    best = None
    bestd = None
    for dr in (0, 1):
        for dg in (0, 1):
            for db in (0, 1):
                cand = np.minimum(lo + np.array([dr, dg, db]), m - 1)
                idx = (cand[:, 0] * m + cand[:, 1]) * m + cand[:, 2]
                d = ((lab_grid[idx] - target) ** 2).sum(axis=1)
                if best is None:
                    best, bestd = cand, d
                else:
                    better = d < bestd
                    best = np.where(better[:, None], cand, best)
                    bestd = np.where(better, d, bestd)
    chosen = send[np.minimum(best, top)].astype(np.uint8)
    res = flat.copy()
    res[dark] = chosen[inv.reshape(-1)]
    return res.reshape(out.shape)


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
    lut = _wb_lut((float(gains[0]), float(gains[1]), float(gains[2])),
                  (float(BLACK_POINT), float(LOW_END), float(LOW_FULL),
                   float(LOW_RED), float(LOW_BLUE)))
    arr = steady(np.asarray(img), hard=hard, floor=floor)
    out = np.empty_like(arr)
    for c in range(3):
        out[..., c] = lut[c][arr[..., c]]
    if NEAREST_COLOUR:
        out = nearest_colour(out, PANEL_CAP, BIT_DEPTH)
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
