"""The Tessera sting on the wall: the final render itself, framed for a square.

The sting is tessera/Design/Logos/record/final/tessera-record-final-*.mp4
(a 16:9 film: the lattice fades up, the disc builds along its groove while
it spins down and locks, centred, by about 1.3 s; from about 2.8 s the mark
slides left and the name is revealed; hold to 5 s). The wall gets that
footage as it is, not a redrawing. The 720p encode ships with the brain (the
same render before its 4K upscale) and is decoded with ffmpeg, once per
wall size, into frames the wall's size, kept on disk after that.

A square panel cannot show a 16:9 frame whole at any useful size, so the
frame follows the picture: each frame is cut to the bright content's box,
padded, and that box only ever grows over the film. While the disc is alone
the box is the disc, so it fills the panel; as the name arrives the box
widens and the cut zooms out to the whole lockup, letterboxed. Nothing is
drawn, only cropped and scaled.

Two cuts: the whole film once, for a boot (`boot_frames`), and the disc
alone, the frames before the name arrives, going round while the wall waits
on something such as a picture being drawn (`icon_frame`).
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import threading

import numpy as np
from PIL import Image

FPS = 24
VIDEO = os.path.join(os.path.dirname(__file__), "..", "assets", "tessera-record-final-720p.mp4")
CACHE_DIR = os.path.expanduser("~/.cache/album-art-matrix")
DECODE_W, DECODE_H = 1280, 720          # the encode's own size: no scaling before the cut
LUMA = 120                              # brighter than this is the picture: the tiles and the name,
                                        # not the lattice (~30), the halo or the wipe's feathered trail
PAD = 0.14                              # margin around the content box, as a share of its long side
LOOP_GROW = 1.25                        # the disc's box widening this much = the name is arriving
ZOOM_S = 0.6                            # the zoom out from the disc to the lockup, as the name arrives


def _bbox(frame: np.ndarray) -> tuple[int, int, int, int] | None:
    """(x0, y0, x1, y1) of the bright content, or None for a dark frame."""
    lum = frame.max(axis=2)
    rows = np.where((lum > LUMA).any(axis=1))[0]
    cols = np.where((lum > LUMA).any(axis=0))[0]
    if rows.size == 0 or cols.size == 0:
        return None
    return int(cols[0]), int(rows[0]), int(cols[-1]) + 1, int(rows[-1]) + 1


def _padded(box, w: int, h: int) -> tuple[int, int, int, int]:
    """The box with its margin, made square while it is near square (the
    disc), kept within the frame."""
    x0, y0, x1, y1 = box
    bw, bh = x1 - x0, y1 - y0
    long = max(bw, bh)
    pad = long * PAD
    if bw < bh * 1.3:                   # the disc alone: a square cut around it
        side = long + 2 * pad
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        rx0, ry0, rx1, ry1 = cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2
    else:                               # the lockup: its own shape
        rx0, ry0, rx1, ry1 = x0 - pad, y0 - pad, x1 + pad, y1 + pad
    return (max(0, int(rx0)), max(0, int(ry0)), min(w, int(round(rx1))), min(h, int(round(ry1))))


def _cut(frame: np.ndarray, rect, size: int) -> np.ndarray:
    """The rect of the frame, scaled to fit the wall, on black."""
    x0, y0, x1, y1 = rect
    crop = Image.fromarray(frame[y0:y1, x0:x1])
    w, h = crop.size
    if w >= h:
        ow, oh = size, max(1, int(round(h * size / w)))
    else:
        ow, oh = max(1, int(round(w * size / h))), size
    out = Image.new("RGB", (size, size), (0, 0, 0))
    out.paste(crop.resize((ow, oh), Image.LANCZOS), ((size - ow) // 2, (size - oh) // 2))
    return np.asarray(out, dtype=np.uint8)


def _decode(path: str):
    """Every frame of the film, streamed from ffmpeg one at a time so the
    whole film is never in memory at once (121 frames of 720p is a third of
    the Pi)."""
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is not installed")
    cmd = [ffmpeg, "-v", "error", "-i", path,
           "-vf", f"scale={DECODE_W}:{DECODE_H}:flags=area,format=rgb24",
           "-r", str(FPS), "-f", "rawvideo", "-"]
    n = DECODE_W * DECODE_H * 3
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as p:
        while True:
            buf = p.stdout.read(n)
            if len(buf) < n:
                break
            yield np.frombuffer(buf, dtype=np.uint8).reshape(DECODE_H, DECODE_W, 3)


class Sting:
    """One per wall size. Frames are made once and kept on disk."""

    _cache: dict[int, "Sting"] = {}
    _lock = threading.Lock()

    @classmethod
    def get(cls, size: int, video: str = VIDEO) -> "Sting":
        with cls._lock:
            s = cls._cache.get(size)
            if s is None:
                s = cls._cache[size] = Sting(size, video)
            return s

    def __init__(self, size: int, video: str = VIDEO):
        self.size = size
        self.video = video
        self.frames: np.ndarray | None = None       # (n, size, size, 3)
        self.loop_end = 0                           # frames before the name arrives
        self._boot: list[bytes] | None = None
        self._ready = threading.Lock()

    # ---- making the frames --------------------------------------------------
    def _cache_path(self) -> str:
        try:
            with open(self.video, "rb") as fh:
                tag = hashlib.md5(fh.read()).hexdigest()[:10]
        except OSError:
            tag = "none"
        return os.path.join(CACHE_DIR, f"sting-{self.size}-{tag}.npz")

    def ensure(self) -> bool:
        """Frames in hand: from the cache, or decoded now (a few seconds on
        the Pi). False when the film cannot be had, said once."""
        with self._ready:
            if self.frames is not None:
                return True
            path = self._cache_path()
            try:
                z = np.load(path)
                self.frames, self.loop_end = z["frames"], int(z["loop_end"])
                return True
            except (OSError, KeyError, ValueError):
                pass
            try:
                self._build()
            except Exception as exc:
                print(f"[sting] no sting: {exc}", flush=True)
                return False
            try:
                os.makedirs(CACHE_DIR, exist_ok=True)
                np.savez_compressed(path, frames=self.frames, loop_end=self.loop_end)
            except OSError as exc:
                print(f"[sting] could not keep the frames: {exc}", flush=True)
            return True

    def _build(self):
        # Two passes over the film, because a frame of it is 2.7 MB and the
        # Pi cannot hold them all: the first reads only where the picture
        # is, the second makes the cuts with the framing already decided.
        envs, boxes, env = [], [], None
        disc_w, loop_end = None, None
        for i, frame in enumerate(_decode(self.video)):
            box = _bbox(frame)
            boxes.append(box)
            if box is not None:
                env = box if env is None else (min(env[0], box[0]), min(env[1], box[1]),
                                               max(env[2], box[2]), max(env[3], box[3]))
            envs.append(env)
            # the disc's settled width: the widest the box gets while it is
            # still near square; the name is arriving when it grows past that
            if env is not None:
                bw, bh = env[2] - env[0], env[3] - env[1]
                if bw < bh * 1.3:
                    disc_w = bw
                elif loop_end is None and disc_w is not None and bw > disc_w * LOOP_GROW:
                    loop_end = i
        if not envs:
            raise RuntimeError(f"nothing decoded from {self.video}")
        if loop_end is None:
            loop_end = len(envs)
        # The disc's own box, from the frame where it has locked (the last
        # of the disc alone), not the union over the build: the first spark's
        # streak and the spin's overshoot skewed that union and the disc sat
        # off centre. The lockup's own box, from the resting last frame, not
        # the union either: the wipe's feathered trail widened that to the
        # right and the name sat left of centre.
        # The settled disc: the median box over the second half of the disc's
        # time, which is the hold, so neither the build's sparks nor the first
        # frames of the slide have a say. The slide itself starts where the
        # box leaves that median, and that is where the disc alone ends.
        hold = [b for b in boxes[loop_end // 2:loop_end] if b is not None]
        disc_box = tuple(int(np.median([b[k] for b in hold])) for k in range(4)) if hold else None
        final_box = next((b for b in reversed(boxes) if b is not None), None)
        if disc_box is None or final_box is None:
            raise RuntimeError("the film is dark all the way through")
        cx = (disc_box[0] + disc_box[2]) / 2
        slack = (disc_box[2] - disc_box[0]) * 0.03
        for i in range(loop_end // 2, loop_end):
            b = boxes[i]
            if b is not None and abs((b[0] + b[2]) / 2 - cx) > slack:
                loop_end = i
                break
        disc_rect = _padded(disc_box, DECODE_W, DECODE_H)
        final_rect = _padded(final_box, DECODE_W, DECODE_H)
        # framed on the disc until the name arrives, then a short zoom out
        # onto the lockup, both centred on what they hold
        rects = []
        for i in range(len(envs)):
            if i < loop_end:
                rects.append(disc_rect)
            else:
                k = min(1.0, (i - loop_end) / (ZOOM_S * FPS))
                k = 1.0 - (1.0 - k) ** 3
                rects.append(tuple(int(round(a + (b - a) * k)) for a, b in zip(disc_rect, final_rect)))
        cuts = [_cut(frame, rects[i], self.size)
                for i, frame in enumerate(_decode(self.video)) if i < len(rects)]
        self.frames = np.stack(cuts).astype(np.uint8)
        self.loop_end = min(loop_end, len(cuts))
        print(f"[sting] {len(cuts)} frames at {self.size}, the disc alone for the first "
              f"{self.loop_end / FPS:.1f} s", flush=True)

    # ---- the two cuts -------------------------------------------------------
    def boot_frames(self) -> list[bytes]:
        if not self.ensure():
            return []
        if self._boot is None:
            self._boot = [f.tobytes() for f in self.frames]
        return self._boot

    def icon_frame(self, t: float) -> np.ndarray | None:
        """The disc alone, going round: the frames before the name arrives,
        then again from the dark."""
        if not self.ensure() or self.loop_end <= 0:
            return None
        return self.frames[int(t * FPS) % self.loop_end]
