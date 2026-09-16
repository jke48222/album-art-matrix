"""The picture folds into a quiet line while the wall listens to you.

Speech lifts the line; a moving bead means the wall is thinking. A reply
opens the line into the next picture. If nothing was caught, a short dashed
line fades away and the previous face returns. This face is temporary and
appears only after the wake phrase, never while the room is idle.
"""
import time
import numpy as np
from PIL import Image

COLLAPSE = .250
RELEASE = .400
OPEN = .400
DASH = .800
CLOSE = .160
BEAD_PERIOD = 1.200


class Horizon:
    def __init__(self, size, picture=None, clock=time.monotonic):
        self.size, self.clock = size, clock
        self.line_width = max(1, size // 64)
        self.bead_width = 6 * self.line_width
        self.margin = 2 if size < 128 else 9
        self.mid = (size - self.line_width) // 2
        self.source = (np.frombuffer(picture, dtype=np.uint8).reshape(size, size, 3).copy()
                       if picture is not None and len(picture) == size * size * 3
                       else np.zeros((size, size, 3), dtype=np.uint8))
        pixels = self.source.reshape(-1, 3).astype(float)
        bright = pixels.max(axis=1)
        chroma = bright - pixels.min(axis=1)
        score = bright * np.divide(chroma, bright, out=np.zeros_like(bright), where=bright > 0)
        self.ink = pixels[int(score.argmax())] if score.max() > 24 else np.array([232., 226., 213.])
        self.started = self.changed = self.clock()
        self.phase = "listening"
        self.envelope, self.envelope_at = .18, self.started
        self.destination = None

    @property
    def waiting(self):
        return self.phase == "target"

    @property
    def done(self):
        elapsed = self.clock() - self.changed
        return (self.phase == "opening" and elapsed >= OPEN) or (self.phase == "failed" and elapsed >= DASH + CLOSE)

    def level(self, db):
        now = self.clock()
        decay = np.exp(-(now - self.envelope_at) / RELEASE)
        self.envelope = max(.18, self.envelope * decay, min(1., max(0., (db + 55) / 35)))
        self.envelope_at = now

    def think(self):
        self.phase, self.changed = "thinking", self.clock()

    def open(self):
        self.phase, self.changed = "target", self.clock()

    def target(self, frame):
        self.destination = np.asarray(frame, dtype=np.uint8).reshape(self.size, self.size, 3).copy()
        self.phase, self.changed = "opening", self.clock()

    def fail(self):
        self.phase, self.changed = "failed", self.clock()

    def _fold(self, picture, fraction):
        height = max(self.line_width, min(self.size, round(self.line_width + (self.size-self.line_width) * fraction)))
        result = np.zeros_like(self.source)
        top = (self.size-height)//2
        result[top:top+height] = np.asarray(Image.fromarray(picture).resize((self.size, height), Image.Resampling.BILINEAR))
        return result

    def frame_at(self, t):
        if self.phase == "opening":
            return self._fold(self.destination, min(1., t / OPEN))
        age = self.clock() - self.started
        if self.phase == "listening" and age < COLLAPSE:
            folded = self._fold(self.source, 1-(age/COLLAPSE)**.7)
            return folded
        result = np.zeros_like(self.source)
        loud = max(.18, self.envelope * np.exp(-(self.clock()-self.envelope_at)/RELEASE))
        ink = np.rint(self.ink * (.3 + .7*loud)).astype(np.uint8)
        x0, x1 = self.margin, self.size-self.margin
        result[self.mid:self.mid+self.line_width, x0:x1] = ink
        if self.phase == "thinking":
            start = x0 + int((t % BEAD_PERIOD)/BEAD_PERIOD * (x1-x0-self.bead_width+1))
            result[self.mid:self.mid+self.line_width, start:start+self.bead_width] = np.maximum(self.ink, 180).astype(np.uint8)
        elif self.phase == "failed":
            gap = 3*self.line_width
            for x in range(x0+gap, x1, gap*2):
                result[self.mid:self.mid+self.line_width, x:min(x+gap,x1)] = 0
            result = np.rint(result * max(0, 1-max(0,t-DASH)/CLOSE)).astype(np.uint8)
        elif loud > .55:
            # Only the ends fray; the centre remains physically still.
            reach = max(1, round(2*self.line_width*loud))
            phase = int(t*18) % 2
            for x, sign in ((x0, -1), (x1-1, 1)):
                y = self.mid + (phase*2-1)*reach
                result[max(0,y):min(self.size,y+self.line_width), max(0,x-sign):min(self.size,x-sign+self.line_width)] = ink
        return result
