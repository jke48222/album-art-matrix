#!/usr/bin/env python3
"""Bake the rest of the world into the wall's font.

Two sources, one table:
  Galmuri7 (OFL)  Latin accents and extensions, smart punctuation, symbols;
                  drawn to match the ASCII cut it already lives beside.
  Misaki (free)   the venerable 8x8: kana, the JIS kanji, and JIS's own
                  Greek and Cyrillic blocks. Shifted one row down at bake
                  time so every script shares one baseline.

Coverage is discovered, not assumed: a codepoint is included only when its
render is non-blank and differs from the font's own .notdef box.

world7.bin entries, sorted by codepoint:
  u32 cp | u8 advance | i8 dy | u8 nrows | nrows bytes (bit 7 = leftmost)
dy is relative to the glyph band's top row; accents may rise one above
(dy -1), descenders may sink below (nrows > 7). Loaders binary-search.
"""
import os
import struct
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FONTS = os.path.join(REPO, "assets", "fonts")
OUTS = [os.path.join(REPO, "brain", "art", "world7.bin"),
        os.path.join(REPO, "tessera", "Tessera", "World7.bin")]

GALMURI_RANGES = [
    (0x00A1, 0x00FF), (0x0100, 0x017F), (0x0180, 0x024F),
    (0x2000, 0x206F), (0x20A0, 0x20BF), (0x2100, 0x214F),
    (0x2190, 0x21FF), (0x2600, 0x26FF), (0x2700, 0x27BF),
]
MISAKI_RANGES = [
    (0x0370, 0x03FF), (0x0400, 0x04FF),
    (0x3000, 0x303F), (0x3041, 0x309F), (0x30A0, 0x30FF),
    (0x4E00, 0x9FFF), (0xFF01, 0xFF5E),
]
SKIP = set(range(0xAC00, 0xD7A4)) | set(range(0x3131, 0x3164))


def render(font, ch, dy=0):
    img = Image.new("L", (14, 14), 0)
    ImageDraw.Draw(img).text((0, dy), ch, font=font, fill=255)
    return np.asarray(img) > 127


def bake(font, ranges, dy_shift, notdef_probe):
    nd = render(font, notdef_probe, dy_shift)
    out = {}
    for lo, hi in ranges:
        for cp in range(lo, hi + 1):
            if cp in SKIP or cp == 0x00AD:
                continue
            ch = chr(cp)
            a = render(font, ch, dy_shift)
            if not a.any() or np.array_equal(a, nd):
                continue
            ys, xs = np.where(a)
            top, bot = int(ys.min()), int(ys.max())
            width = int(xs.max()) + 1
            if width > 8 or bot > 10:
                continue
            adv = max(2, min(9, int(font.getlength(ch))))
            rows = []
            for y in range(top, bot + 1):
                mask = 0
                for x in range(min(8, width)):
                    if a[y, x]:
                        mask |= 1 << (7 - x)
                rows.append(mask)
            # dy relative to the band's top (render row 1)
            out[cp] = (adv, top - 1, rows)
    return out


def main():
    galmuri = ImageFont.truetype(os.path.join(FONTS, "Galmuri7.ttf"), 8)
    misaki = ImageFont.truetype(os.path.join(FONTS, "misaki_gothic.ttf"), 8)

    table = bake(misaki, MISAKI_RANGES, 1, "͸")
    table.update(bake(galmuri, GALMURI_RANGES, 0, "͸"))

    blob = bytearray()
    for cp in sorted(table):
        adv, dy, rows = table[cp]
        blob += struct.pack(">IbbB", cp, adv, dy, len(rows))
        blob += bytes(rows)
    for out in OUTS:
        with open(out, "wb") as fh:
            fh.write(blob)
    print(f"baked {len(table)} glyphs, {len(blob)} bytes")
    by_block = {}
    for cp in table:
        block = ("latin" if cp < 0x370 else "greek" if cp < 0x400
                 else "cyrillic" if cp < 0x500 else "punct/symbols"
                 if cp < 0x3000 else "kana/cjk-punct" if cp < 0x4E00
                 else "kanji" if cp < 0xA000 else "fullwidth")
        by_block[block] = by_block.get(block, 0) + 1
    for k, v in sorted(by_block.items()):
        print(f"  {k}: {v}")
    if len(table) < 2000:
        sys.exit("coverage suspiciously small")


if __name__ == "__main__":
    main()
