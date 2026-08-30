#!/usr/bin/env python3
"""Bake all 11,172 modern Hangul syllables (plus the 51 compatibility jamo)
from Galmuri7 into a packed bitmap the wall's font machinery can letter.

Why baking instead of shipping the TTF: the renderers on both sides speak
row-bitmask glyphs, one code path, no text stack, no antialiasing to fight.
Galmuri7 (OFL) renders pixel-exact at ppem 8: every syllable is 7 rows tall
in the same vertical band as our ASCII 5x7, 7 columns wide, advance 8. So a
glyph packs to 7 bytes, bit 6 the leftmost pixel, and the whole language is
78KB, which is nothing, for everything.

Output: hangul7.bin = 11172 syllable glyphs (U+AC00..U+D7A3), then 51 jamo
(U+3131..U+3163). Offset arithmetic only; no header.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TTF = os.path.join(REPO, "assets", "fonts", "Galmuri7.ttf")
OUTS = [
    os.path.join(REPO, "brain", "art", "hangul7.bin"),
    os.path.join(REPO, "tessera", "Tessera", "Hangul7.bin"),
]

def main():
    font = ImageFont.truetype(TTF, 8)
    blob = bytearray()
    ranges = [(0xAC00, 0xD7A3), (0x3131, 0x3163)]
    empty = 0
    for lo, hi in ranges:
        for cp in range(lo, hi + 1):
            img = Image.new("L", (10, 10), 0)
            ImageDraw.Draw(img).text((0, 0), chr(cp), font=font, fill=255)
            a = np.asarray(img) > 127
            rows = []
            for y in range(1, 8):                 # the glyph band
                mask = 0
                for x in range(7):
                    if a[y, x]:
                        mask |= 1 << (6 - x)
                rows.append(mask)
            if not any(rows):
                empty += 1
            blob.extend(rows)
    for out in OUTS:
        with open(out, "wb") as fh:
            fh.write(blob)
    total = sum(hi - lo + 1 for lo, hi in ranges)
    print(f"baked {total} glyphs, {len(blob)} bytes, {empty} blank -> "
          + ", ".join(os.path.relpath(o, REPO) for o in OUTS))
    if empty > total // 100:
        sys.exit("too many blanks; the font did not cover the range")

if __name__ == "__main__":
    main()
