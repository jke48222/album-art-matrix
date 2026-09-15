#!/usr/bin/env python3
"""Tessera marks, round two: six directions, five colourways, a sting each.

Every mark is drawn into a 100 x 100 box by one function. Wordmarks are glyph
outlines pulled from the app's own faces (Technor and Switzer, in
tessera/Tessera/Fonts) with fontTools, kerning read from each face's GPOS
table, so the files carry no live text. The animated elements carry classes
and per-element delays as CSS custom properties; the SVG files ignore them,
the board and the render pages animate them.

    python3 tessera/Tools/logos.py [board.html]

writes tessera/Design/Logos/<direction>/ (mark, lockup per colourway and
ground, one icon), a board page, a contact sheet and six render pages that
tessera/Tools/logos_video.py turns into MP4 stings.
"""
import base64
import math
import os
import random
import sys

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "..", "Tessera", "Fonts")
OUT = os.path.join(HERE, "..", "Design", "Logos")

# The app's Ink palette (Theme.swift) plus the paper set for the light ground.
THEMES = {
    "dark": dict(ground="#0B0A09", ink="#EAE4D8", dim="#96907F", ghost="#1D1A17",
                 unlit="#2A2622", body="#161311"),
    "light": dict(ground="#F1ECE2", ink="#17150F", dim="#7A7466", ghost="#DED7C9",
                  unlit="#CBC3B3", body="#17150F"),
}

# Colourways. The accent is whatever is lit. "ink" is the one-colour cut:
# no accent, no glow, so it engraves and prints.
WAYS = {"amber": "#E8B04B", "vermilion": "#E0491F", "moss": "#7FA87A",
        "cobalt": "#4C7DD6", "white": "#FFFFFF", "ink": None}
RGB = ("#E0491F", "#7FA87A", "#4C7DD6")   # the three dies of one LED, in the app's own hues


def mix(a, b, k):
    a = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(a[i] + (b[i] - a[i]) * k):02X}" for i in range(3))


def num(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def accent(t, way):
    return t["ink"] if WAYS.get(way) is None else WAYS[way]


def radial(pid, cx, cy, r, colour, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{colour}" stop-opacity="{a}"/>' for o, a in stops)
    return (f'<radialGradient id="{pid}" cx="{num(cx)}" cy="{num(cy)}" r="{num(r)}" '
            f'gradientUnits="userSpaceOnUse">{s}</radialGradient>')


# ---------------------------------------------------------------- type

class Face:
    """One font file: outlines, advances and pair kerning."""

    def __init__(self, name):
        self.f = TTFont(os.path.join(FONTS, name))
        self.cmap = self.f.getBestCmap()
        self.gs = self.f.getGlyphSet()
        self.upm = self.f["head"].unitsPerEm
        self.hmtx = self.f["hmtx"].metrics
        self.pairs, self.classed = self._kerning()

    def _kerning(self):
        # Only the lookups the 'kern' feature points at. Pair positioning comes
        # as explicit glyph pairs (format 1) or class pairs (format 2).
        pairs, classed = {}, []
        if "GPOS" not in self.f:
            return pairs, classed
        gpos = self.f["GPOS"].table
        idx = set()
        for fr in gpos.FeatureList.FeatureRecord:
            if fr.FeatureTag == "kern":
                idx.update(fr.Feature.LookupListIndex)
        for i in sorted(idx):
            lk = gpos.LookupList.Lookup[i]
            for st in lk.SubTable:
                if lk.LookupType == 9:
                    if st.ExtensionLookupType != 2:
                        continue
                    st = st.ExtSubTable
                elif lk.LookupType != 2:
                    continue
                cov = st.Coverage.glyphs
                if st.Format == 1:
                    for g1, ps in zip(cov, st.PairSet):
                        for r in ps.PairValueRecord:
                            v = getattr(r.Value1, "XAdvance", 0) if r.Value1 else 0
                            pairs.setdefault((g1, r.SecondGlyph), v)
                elif st.Format == 2:
                    classed.append((set(cov), st.ClassDef1.classDefs,
                                    st.ClassDef2.classDefs, st.Class1Record))
        return pairs, classed

    def kern(self, g1, g2):
        if (g1, g2) in self.pairs:
            return self.pairs[(g1, g2)]
        for cov, c1, c2, recs in self.classed:
            if g1 in cov:
                rec = recs[c1.get(g1, 0)].Class2Record[c2.get(g2, 0)]
                return getattr(rec.Value1, "XAdvance", 0) if rec.Value1 else 0
        return 0

    def layout(self, text, size, tracking=0.0):
        """Per-glyph paths at `size` units per em, baseline y=0, from x=0.
        Returns (paths, advance width, bbox of the drawn outlines)."""
        k = size / self.upm
        x, prev, paths = 0.0, None, []
        bb = [math.inf, math.inf, -math.inf, -math.inf]
        for ch in text:
            g = self.cmap[ord(ch)]
            if prev:
                x += self.kern(prev, g) * k
            pen = SVGPathPen(self.gs, ntos=num)
            self.gs[g].draw(TransformPen(pen, (k, 0, 0, -k, x, 0)))
            d = pen.getCommands()
            if d:
                paths.append(d)
                bp = BoundsPen(self.gs)
                self.gs[g].draw(TransformPen(bp, (k, 0, 0, -k, x, 0)))
                b = bp.bounds
                bb = [min(bb[0], b[0]), min(bb[1], b[1]), max(bb[2], b[2]), max(bb[3], b[3])]
            x += self.hmtx[g][0] * k + tracking
            prev = g
        return paths, x - tracking, bb


FACES = {}


def face(name):
    if name not in FACES:
        FACES[name] = Face(name)
    return FACES[name]


def wordmark(spec, fill, left, cy, anim):
    """Outline the wordmark and place it: left edge at `left`, the drawn box
    centred on `cy`. Each glyph gets its own group so a sting can bring the
    letters in one at a time."""
    f = face(spec["font"])
    paths, w, b = f.layout(spec["text"], spec["size"], spec.get("tracking", 0.0))
    dx, dy = left - b[0], cy - (b[1] + b[3]) / 2
    chars = "".join(f'<g class="ch" style="--i:{i}"><path d="{d}"/></g>' for i, d in enumerate(paths))
    g = (f'<g class="wm {anim}" transform="translate({num(dx)} {num(dy)})" fill="{fill}">{chars}</g>')
    return g, b[2] - b[0]


# ---------------------------------------------------------------- marks
# Each returns (defs, body) for a 100 x 100 box with no background.
# `p` prefixes ids so several marks can share one page.

def emitter(t, way, p):
    """Four by four round emitters, one lit. The current icon, made a mark."""
    acc, mono = accent(t, way), way == "ink"
    n, cell, r = 4, 25.0, 8.6
    lit = (1, 1)
    lx, ly = cell * lit[0] + cell / 2, cell * lit[1] + cell / 2
    hr = 37.5  # the halo fades to nothing exactly at the box edge
    defs, out = "", []
    if not mono:
        defs = radial(p + "h", lx, ly, hr, acc, ((0, .6), (.4, .18), (1, 0)))
        out.append(f'<circle class="halo" cx="{lx}" cy="{ly}" r="{hr}" fill="url(#{p}h)"/>')
    for gy in range(n):
        for gx in range(n):
            cx, cy = cell * gx + cell / 2, cell * gy + cell / 2
            if (gx, gy) == lit:
                out.append(f'<circle class="lit" cx="{cx}" cy="{cy}" r="{num(r * 1.42)}" fill="{acc}"/>')
                if not mono:
                    out.append(f'<circle class="core" cx="{cx}" cy="{cy}" r="{num(r * 0.78)}" '
                               f'fill="{mix(acc, "#FFFFFF", 0.5)}"/>')
            else:
                dist = max(abs(gx - lit[0]), abs(gy - lit[1]))
                k = max(0.0, 1 - dist / 3.0) ** 2
                warm = t["unlit"] if mono else mix(t["unlit"], acc, 0.34 * k)
                if warm != t["unlit"]:
                    out.append(f'<circle class="u w" style="--u:{t["unlit"]};--w:{warm}" '
                               f'cx="{cx}" cy="{cy}" r="{r}" fill="{warm}"/>')
                else:
                    out.append(f'<circle class="u" cx="{cx}" cy="{cy}" r="{r}" fill="{warm}"/>')
    return defs, "".join(out)


def mosaic_t(t, way, p):
    """A T laid in nine tiles with grout. The rest of the lattice stays, unlit."""
    acc = accent(t, way)
    cell, size, rx = 20.0, 16.0, 1.8
    order = [(0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (2, 1), (2, 2), (2, 3), (2, 4)]
    out = []
    for gy in range(5):
        for gx in range(5):
            x, y = gx * cell + (cell - size) / 2, gy * cell + (cell - size) / 2
            if (gx, gy) in order:
                d = 0.35 + order.index((gx, gy)) * 0.09
                out.append(f'<rect class="tile" style="--d:{d:.2f}s" x="{num(x)}" y="{num(y)}" '
                           f'width="{size}" height="{size}" rx="{rx}" fill="{acc}"/>')
            else:
                out.append(f'<rect class="g" x="{num(x)}" y="{num(y)}" width="{size}" height="{size}" '
                           f'rx="{rx}" fill="{t["ghost"]}"/>')
    return "", "".join(out)


RECORD_N, RECORD_R, RECORD_HOLE = 9, 48.5, 10.5
# The colourful record: a sweep around the disc by angle, warm to cool
# through the app's own hues and back, lifting towards the spindle the way
# a label does. Stops are evenly spaced around the circle.
SPECTRUM = ["#E8B04B", "#E0491F", "#C9407A", "#7B4FC7", "#4C7DD6", "#5FA88F"]


def spectrum_colour(ang, r, R=RECORD_R):
    """ang 0..1 clockwise from twelve; r the tile's distance from centre."""
    n = len(SPECTRUM)
    x = (ang * n) % n
    i, k = int(x), x - int(x)
    c = mix(SPECTRUM[i], SPECTRUM[(i + 1) % n], k)
    return mix(c, "#FFFFFF", 0.28 * max(0.0, 1 - r / R))



def record_cells(n=RECORD_N, R=RECORD_R, hole=RECORD_HOLE, ss=16):
    """The Record mark's geometry in the mark's 0..100 box. Returns the
    lattice cells (cx, cy, size, chebyshev distance from centre) and the lit
    tiles (cx, cy, size, radius, clockwise angle 0..1 from twelve), each lit
    tile sized by how much of the disc sits under its cell. With nine cells
    a side the spindle hole is the centre cell."""
    cell = 100 / n
    mx = cell * 0.86
    lattice, lit = [], []
    for gy in range(n):
        for gx in range(n):
            cx, cy = gx * cell + cell / 2, gy * cell + cell / 2
            lattice.append((cx, cy, mx, max(abs(gx - (n - 1) / 2), abs(gy - (n - 1) / 2))))
            cov = 0
            for j in range(ss):
                for i in range(ss):
                    px = gx * cell + (i + 0.5) * cell / ss - 50
                    py = gy * cell + (j + 0.5) * cell / ss - 50
                    if hole <= math.hypot(px, py) <= R:
                        cov += 1
            s = mx * math.sqrt(cov / (ss * ss))
            if s < 0.8:
                continue
            ang = (math.atan2(cx - 50, -(cy - 50)) % (2 * math.pi)) / (2 * math.pi)
            lit.append((cx, cy, s, math.hypot(cx - 50, cy - 50), ang))
    return lattice, lit


def record(t, way, p):
    """A record, tessellated, on an unlit lattice: nine by nine cells, the
    spindle hole the centre cell. Each lit tile is sized by how much of the
    disc sits under it, and the unlit tile shows around it at the rim."""
    acc = None if way == "spectrum" else accent(t, way)
    lattice, lit = record_cells()
    ghost = [f'<rect class="g" x="{num(cx - mx / 2)}" y="{num(cy - mx / 2)}" width="{num(mx)}" '
             f'height="{num(mx)}" rx="1.1" fill="{t["ghost"]}"/>' for cx, cy, mx, d in lattice]
    tiles = [f'<rect class="tile" style="--d:{0.35 + ang * 0.9:.2f}s" x="{num(cx - s / 2)}" '
             f'y="{num(cy - s / 2)}" width="{num(s)}" height="{num(s)}" '
             f'rx="{num(min(1.1, s * 0.12))}" fill="{acc or spectrum_colour(ang, r)}"/>' for cx, cy, s, r, ang in lit]
    return "", "".join(ghost + tiles)


# Hand-set tiles never sit square. Rotation in degrees and a nudge in units.
JITTER = [(-4, -.6, .4), (3, .5, -.5), (-2, .2, .7), (5, -.4, .3), (0, 0, 0),
          (-3, .6, -.2), (2, -.5, -.6), (-5, .3, .5), (4, .6, .2)]
PRESS = [0, 1, 2, 3, 5, 6, 7, 8, 4]   # reading order, the centre last


def handset(t, way, p):
    """Nine tiles pressed into a bed by hand, each a few degrees off. The
    grid the wall is, drawn the way a mosaic is actually made. Centre lit."""
    acc, mono = accent(t, way), way == "ink"
    cell, size = 100 / 3, 25.0
    defs = "" if mono else radial(p + "h", 50, 50, 40, acc, ((0, .5), (.45, .14), (1, 0)))
    out = [f'<rect class="bed" width="100" height="100" rx="9" fill="{t["ghost"]}"/>']
    if not mono:
        out.append(f'<circle class="halo" cx="50" cy="50" r="40" fill="url(#{p}h)"/>')
    for i in range(9):
        gx, gy = i % 3, i // 3
        rot, dx, dy = JITTER[i]
        cx, cy = gx * cell + cell / 2 + dx, gy * cell + cell / 2 + dy
        lit = i == 4
        dist = max(abs(gx - 1), abs(gy - 1))
        fill = acc if lit else (t["ink"] if mono else mix(t["ink"], acc, 0.16 if dist == 1 else 0))
        d = 0.15 + PRESS.index(i) * 0.1
        out.append(f'<g transform="rotate({rot} {num(cx)} {num(cy)})">'
                   f'<rect class="tile{" lit" if lit else ""}" style="--d:{d:.2f}s" x="{num(cx - size / 2)}" '
                   f'y="{num(cy - size / 2)}" width="{size}" height="{size}" rx="2.6" fill="{fill}"/></g>')
    return defs, "".join(out)


DIES = [(35, 39), (65, 39), (50, 64)]


def triad(t, way, p):
    """One LED up close: the black package and the three dies inside it that
    mix to make every colour the wall shows. A tessera is one of these."""
    mono = way == "ink"
    if way == "rgb":
        dies, acc = RGB, "#E8B04B"
    elif mono:
        dies, acc = (t["ink"],) * 3, None
    else:
        a = WAYS[way]
        dies, acc = (mix(a, "#0B0A09", .3), a, mix(a, "#FFFFFF", .3)), a
    defs = "" if acc is None else radial(p + "m", 50, 48, 34, acc, ((0, .75), (.55, .25), (1, 0)))
    out = [f'<rect class="pkg" width="100" height="100" rx="24" fill="{t["body"]}"/>']
    if acc:
        out.append(f'<circle class="mix" cx="50" cy="48" r="34" fill="url(#{p}m)"/>')
    for k, (x, y) in enumerate(DIES):
        d = f"{0.4 + k * 0.28:.2f}s"
        out.append(f'<circle class="ring" style="--d:{d}" cx="{x}" cy="{y}" r="10.5" fill="none" '
                   f'stroke="{dies[k]}" stroke-width="2" opacity="0"/>')
        out.append(f'<circle class="die" style="--d:{d}" cx="{x}" cy="{y}" r="10.5" fill="{dies[k]}"/>')
    return defs, "".join(out)


def cover(t, way, p):
    """The smallest album cover: a sunset in nine tiles, the way the wall
    reduces any picture to tesserae. The picture keeps its own tones on both
    grounds; only the grout changes."""
    acc = accent(t, way)
    D = "#0B0A09"
    sky_hi, sky_lo, sun, gnd = mix(acc, D, .68), mix(acc, D, .38), acc, mix(acc, D, .86)
    grid = [[sky_hi] * 3, [sky_lo, sun, sky_lo], [gnd] * 3]
    palette = [sky_hi, sky_lo, sun, gnd, t["ghost"]]
    rng = random.Random(7)
    cell, size = 100 / 3, 30.4
    out = []
    for r in range(3):
        for c in range(3):
            cs = rng.sample(palette, 4)
            style = ";".join(f"--c{i}:{cs[i]}" for i in range(4)) + f";--cf:{grid[r][c]};--d:{0.1 + r * .2 + c * .05:.2f}s"
            x, y = c * cell + (cell - size) / 2, r * cell + (cell - size) / 2
            out.append(f'<rect class="tile{" sun" if (r, c) == (1, 1) else ""}" style="{style}" x="{num(x)}" '
                       f'y="{num(y)}" width="{size}" height="{size}" rx="3" fill="{grid[r][c]}"/>')
    return "", "".join(out)


DIRECTIONS = [
    dict(slug="emitter", name="Emitter", kept=True, mark=emitter, hero="amber", icon_scale=0.74,
         word=dict(font="Technor-Semibold.otf", text="Tessera", size=74), wm="wm-slide",
         idea="Four by four round emitters, one lit. The mark the app already has, reduced to a "
              "grid that holds together at 24 px.",
         note="Safest continuity with the icon on your phone. The ink cut drops the glow and "
              "keeps the lit dot as a solid.",
         sting="Power on", sting_desc="The lattice is there first, dark. One tile flickers "
              "twice the way an LED does when a panel takes power, holds, and its bloom "
              "spreads to the neighbours. The name slides in from the light."),
    dict(slug="mosaic", name="Mosaic T", kept=True, mark=mosaic_t, hero="amber", icon_scale=0.68,
         word=dict(font="Technor-Bold.otf", text="TESSERA", size=60, tracking=4.8), wm="wm-track",
         idea="A T laid in nine tiles with grout between them, on a lattice that stays visible "
              "unlit. The word made literal: a tessera is one tile, the letter is the mosaic.",
         note="Flat, one colour per cut, no gradients, so it goes on a laser-cut plate or the "
              "back of the wall as easily as on a screen.",
         sting="Laying", sting_desc="The unlit lattice fades up, then the nine tiles are set "
              "one at a time, left to right along the bar and down the stem, each landing a "
              "little large and settling. The letters of the name close up from wide tracking."),
    # icon_scale 1.0: the lattice runs to the icon's edge (half a gutter of
    # air, the lattice's own rhythm), the way the wall fills its frame.
    dict(slug="record", name="Record", kept=True, mark=record, hero="white", icon_scale=1.0,
         word=dict(font="Technor-Bold.otf", text="TESSERA", size=58, tracking=5.5), wm="wm-fade",
         idea="A record, tessellated, on its unlit lattice. Nine by nine cells, the spindle "
              "hole the centre cell; each lit tile is sized by how much of the disc sits under "
              "it, and at the rim the dark tile shows around the small lit one. The colour sweeps "
              "around the disc by angle, warm to cool through the app's own hues, lifting towards "
              "the spindle like a label.",
         note="The lattice makes the disc read as something shown on the wall rather than a "
              "halftone print. Quietest of the six.",
         sting="Spin-up", sting_desc="The lattice fades up and the disc wipes on clockwise from "
              "twelve, tile by tile, one revolution. The name fades in behind it."),
    dict(slug="handset", name="Handset", kept=False, mark=handset, hero="amber", icon_scale=0.72,
         word=dict(font="Switzer-Medium.otf", text="tessera", size=76, tracking=-0.6), wm="wm-rise",
         idea="Nine tiles pressed into a bed by hand, each a few degrees off square, the centre "
              "one lit. The grid the wall is, drawn the way a mosaic is actually made.",
         note="The warmest of the six and the only one with any hand in it. The tilt is small "
              "enough to survive 29 px as texture rather than mess.",
         sting="Pressing in", sting_desc="Each tile drops in over-rotated and oversized and is "
              "pressed flat into the bed, reading order, the centre last. When the centre "
              "seats it lights, and the name rises from under the mark."),
    dict(slug="triad", name="Triad", kept=False, mark=triad, hero="rgb", icon_scale=0.72,
         word=dict(font="Technor-Medium.otf", text="Tessera", size=74), wm="wm-type",
         idea="One LED up close: the black package and the three dies inside it, red, green and "
              "blue, that mix to make every colour the wall shows. A tessera is one of these, "
              "4,096 times.",
         note="The truest to the hardware. In the single-accent colourways the three dies "
              "become three tints, a monochrome module.",
         sting="Mixing", sting_desc="The package appears. Red, green, then blue pop on, each "
              "throwing a ring, and when all three are lit their mix blooms in the middle "
              "and settles to a glow. The name types in one letter at a time."),
    dict(slug="cover", name="Cover", kept=False, mark=cover, hero="amber", icon_scale=0.72,
         word=dict(font="Switzer-Semibold.otf", text="Tessera", size=72), wm="wm-focus",
         idea="The smallest album cover: a sunset in nine tiles, the way the wall reduces any "
              "picture to tesserae. Sky, sun, ground. The picture keeps its own tones on paper; "
              "only the grout changes.",
         note="The one about the art rather than the hardware. Each colourway is a different "
              "time of day: amber dusk, vermilion sunset, moss morning, cobalt night, ink "
              "greyscale.",
         sting="Painting", sting_desc="The tiles flicker through wrong colours, the way a "
              "panel does while a picture is still arriving, and resolve row by row from the "
              "sky down. The name comes into focus."),
]


def ways_for(d):
    extra = {"triad": ["rgb"], "record": ["spectrum"]}.get(d["slug"], [])
    return extra + list(WAYS)


# ---------------------------------------------------------------- files

def svg(w, h, defs, body, cls=""):
    defs = f"<defs>{defs}</defs>" if defs else ""
    c = f' class="{cls}"' if cls else ""
    return f'<svg xmlns="http://www.w3.org/2000/svg"{c} viewBox="0 0 {num(w)} {num(h)}">{defs}{body}</svg>'


def mark_svg(d, tn, way, p):
    defs, body = d["mark"](THEMES[tn], way, p)
    return svg(100, 100, defs, body, f"h-{d['slug']}")


def icon_svg(d, p, way=None):
    """The mark on the app's dark ground, sized for a home screen."""
    t = THEMES["dark"]
    defs, body = d["mark"](t, way or d["hero"], p)
    s = d["icon_scale"]
    off = num((100 - 100 * s) / 2)
    return svg(100, 100, defs,
               f'<rect width="100" height="100" fill="{t["ground"]}"/>'
               f'<g transform="translate({off} {off}) scale({s})">{body}</g>', f"h-{d['slug']}")


def lockup_svg(d, tn, way, p):
    t = THEMES[tn]
    defs, body = d["mark"](t, way, p)
    text, tw = wordmark(d["word"], t["ink"], 110 + 28, 60, d["wm"])
    return svg(110 + 28 + tw + 12, 120, defs, f'<g transform="translate(10 10)">{body}</g>{text}',
               f"h-{d['slug']}")


def write(path, s):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(s)


def font_uri(name):
    with open(os.path.join(FONTS, name), "rb") as fh:
        return "data:font/otf;base64," + base64.b64encode(fh.read()).decode()


# ---------------------------------------------------------------- motion
# One sting per direction. Elements start from their `from` state during
# their delay (fill-mode both) and rest at the drawn state, so a page
# without the .run class shows the finished mark.

ANIM_CSS = """
.hero svg .tile,.hero svg .lit,.hero svg .core,.hero svg .halo,.hero svg .die,.hero svg .ring,
.hero svg .mix,.hero svg .u,.hero svg .g,.hero svg .bed,.hero svg .pkg{transform-box:fill-box;transform-origin:50% 50%}
@keyframes fadein{from{opacity:0}to{opacity:1}}
@keyframes flick{0%{opacity:0}26%{opacity:1}38%{opacity:0}52%{opacity:1}66%{opacity:.3}100%{opacity:1}}
@keyframes bloom{from{transform:scale(0);opacity:0}to{transform:scale(1);opacity:1}}
@keyframes warm{from{fill:var(--u)}to{fill:var(--w)}}
@keyframes lay{0%{transform:scale(1.7);opacity:0}55%{opacity:1}100%{transform:scale(1);opacity:1}}
@keyframes spin{from{transform:scale(0);opacity:0}to{transform:scale(1);opacity:1}}
@keyframes press{0%{transform:rotate(38deg) scale(1.4);opacity:0}45%{opacity:1}100%{transform:none;opacity:1}}
@keyframes pop{0%{transform:scale(0)}100%{transform:scale(1)}}
@keyframes ring{0%{transform:scale(1);opacity:.7}100%{transform:scale(2.6);opacity:0}}
@keyframes mixin{0%{transform:scale(0);opacity:0}45%{transform:scale(1.3);opacity:1}100%{transform:scale(1);opacity:1}}
@keyframes paint{0%{fill:var(--c0);animation-timing-function:step-end}25%{fill:var(--c1);animation-timing-function:step-end}
  50%{fill:var(--c2);animation-timing-function:step-end}75%{fill:var(--c3);animation-timing-function:step-end}100%{fill:var(--cf)}}
@keyframes wm-slide{from{opacity:0;transform:translateX(-7px)}to{opacity:1;transform:none}}
@keyframes wm-track{from{opacity:0;transform:translateX(calc((var(--i) - 3) * 9px))}to{opacity:1;transform:none}}
@keyframes wm-fade{from{opacity:0;transform:translateX(5px)}to{opacity:1;transform:none}}
@keyframes wm-rise{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
@keyframes wm-type{from{opacity:0}to{opacity:1}}
@keyframes wm-focus{from{opacity:0;filter:blur(8px)}to{opacity:1;filter:blur(0)}}

.run .h-emitter .u{animation:fadein .35s both}
.run .h-emitter .w{animation:fadein .35s both,warm .6s both .95s}
.run .h-emitter .lit,.run .h-emitter .core{animation:flick .55s both .5s}
.run .h-emitter .halo{animation:bloom .8s cubic-bezier(.2,.8,.2,1) both .85s}
.run .h-emitter .wm .ch{animation:wm-slide .5s cubic-bezier(.2,.8,.2,1) both calc(1.2s + var(--i) * .045s)}

.run .h-mosaic .g{animation:fadein .4s both}
.run .h-mosaic .tile{animation:lay .5s cubic-bezier(.2,1.2,.4,1) both var(--d)}
.run .h-mosaic .wm .ch{animation:wm-track .55s cubic-bezier(.2,.8,.2,1) both calc(1.3s + var(--i) * .03s)}

.run .h-record .g{animation:fadein .4s both}
.run .h-record .tile{animation:spin .3s ease-out both var(--d)}
.run .h-record .wm .ch{animation:wm-fade .5s ease-out both calc(1.45s + var(--i) * .05s)}

.run .h-handset .bed{animation:fadein .4s both}
.run .h-handset .tile{animation:press .55s cubic-bezier(.2,1.1,.3,1) both var(--d)}
.run .h-handset .halo{animation:bloom .7s ease-out both 1.25s}
.run .h-handset .wm .ch{animation:wm-rise .5s cubic-bezier(.2,.8,.2,1) both calc(1.45s + var(--i) * .04s)}

.run .h-triad .pkg{animation:fadein .35s both}
.run .h-triad .die{animation:pop .4s cubic-bezier(.2,1.4,.4,1) both var(--d)}
.run .h-triad .ring{animation:ring .7s ease-out both var(--d)}
.run .h-triad .mix{animation:mixin .9s ease-out both 1.35s}
.run .h-triad .wm .ch{animation:wm-type .01s steps(1,end) both calc(1.75s + var(--i) * .07s)}

.run .h-cover .tile{animation:paint .8s both var(--d)}
.run .h-cover .wm{animation:wm-focus .7s ease-out both 1.45s}

@media (prefers-reduced-motion:reduce){.run *{animation:none!important}}
"""

PLAY_JS = """
(function(){
  var heroes=[].slice.call(document.querySelectorAll('.hero'));
  var still=matchMedia('(prefers-reduced-motion: reduce)').matches;
  function play(h){h.classList.remove('run');void h.offsetWidth;h.classList.add('run');}
  heroes.forEach(function(h){
    h.addEventListener('click',function(){play(h)});
    h.addEventListener('keydown',function(e){if(e.key==='Enter'||e.key===' '){e.preventDefault();play(h)}});
  });
  if(still)return;
  var seen=new WeakSet();
  var io=new IntersectionObserver(function(es){es.forEach(function(e){
    if(e.isIntersecting&&!seen.has(e.target)){seen.add(e.target);play(e.target)}})},{threshold:.4});
  heroes.forEach(function(h){io.observe(h)});
  setInterval(function(){heroes.forEach(function(h){if(seen.has(h))play(h)})},7000);
})();
"""

# ---------------------------------------------------------------- board

CSS = """
@font-face{font-family:"Switzer";font-weight:400;src:url(__SW400__) format("opentype")}
@font-face{font-family:"Switzer";font-weight:500;src:url(__SW500__) format("opentype")}
@font-face{font-family:"Technor";font-weight:500;src:url(__TE500__) format("opentype")}
:root{--paper:#F1ECE2;--ink:#17150F;--dim:#7A7466;--hair:#DCD5C7;--amber:#E8B04B;
  --dark:#0B0A09;--dark-ink:#EAE4D8;--light:#F1ECE2;--light-ink:#17150F;
  --sans:"Switzer","Helvetica Neue",Arial,sans-serif;
  --display:"Technor","Switzer","Helvetica Neue",Arial,sans-serif;
  --mono:"Martian Mono",ui-monospace,"SF Mono",Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--paper:#0B0A09;--ink:#EAE4D8;--dim:#96907F;--hair:#26231F}}
:root[data-theme="dark"]{--paper:#0B0A09;--ink:#EAE4D8;--dim:#96907F;--hair:#26231F}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--sans);font-size:16px;line-height:1.55;-webkit-font-smoothing:antialiased}
.frame{width:min(1180px,100vw - 2*max(24px,4vw));margin:0 auto}
header{padding:72px 0 40px}
.lbl{font-family:var(--mono);font-size:11px;font-weight:500;letter-spacing:.11em;text-transform:uppercase;color:var(--dim);margin:0}
h1{font-family:var(--display);font-weight:500;font-size:clamp(40px,6vw,68px);line-height:1;letter-spacing:-.02em;margin:14px 0 18px;text-wrap:balance}
.dek{max-width:62ch;margin:0;font-size:17px}
.dek + .dek{margin-top:10px;color:var(--dim)}
.plate{display:grid;grid-template-columns:minmax(220px,300px) 1fr;gap:40px;padding:44px 0 48px;border-top:1px solid var(--hair)}
.plate h2{font-family:var(--display);font-weight:500;font-size:28px;letter-spacing:-.01em;margin:0 0 4px;line-height:1.1}
.plate .kind{font-family:var(--mono);font-size:11px;letter-spacing:.11em;text-transform:uppercase;color:var(--dim);margin:0 0 14px}
.plate .kind.new{color:var(--amber)}
.plate p{margin:0 0 12px;font-size:15px;max-width:44ch}
.plate p.note{color:var(--dim)}
.plate p.sting b{font-weight:500}
.plate .file{font-family:var(--mono);font-size:11px;color:var(--dim);letter-spacing:.04em;margin-top:6px}
.hero{position:relative;background:var(--dark);border-radius:6px;padding:40px 48px;display:flex;align-items:center;justify-content:center;min-height:220px;cursor:pointer;outline:none}
.hero:focus-visible{box-shadow:0 0 0 2px var(--amber)}
.hero svg{width:100%;height:auto;max-height:150px;display:block}
.hero .tag{position:absolute;right:14px;bottom:10px;font-family:var(--mono);font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:#96907F;opacity:.7}
.ways{margin-top:14px;display:grid;grid-template-columns:1fr 1fr;gap:14px}
.strip{border-radius:6px;padding:16px 20px;display:flex;align-items:center;gap:18px;flex-wrap:wrap}
.strip.dark{background:var(--dark);color:var(--dark-ink)}
.strip.light{background:var(--light);color:var(--light-ink);box-shadow:inset 0 0 0 1px rgba(23,21,15,.08)}
.strip figure{margin:0;display:flex;flex-direction:column;align-items:center;gap:6px}
.strip figcaption{font-family:var(--mono);font-size:9px;letter-spacing:.1em;text-transform:uppercase;opacity:.55}
.chip{width:56px;height:56px;line-height:0}
.chip svg{width:100%;height:100%}
.tests{margin-top:14px;display:grid;grid-template-columns:1fr 1fr;gap:14px}
.tests .strip svg{display:block;flex:none}
.icon{border-radius:22.5%;overflow:hidden;flex:none;line-height:0}
.icon svg{width:100%;height:100%}
.i60{width:60px;height:60px}.i29{width:29px;height:29px}
.nav{display:flex;align-items:center;gap:8px;font-family:var(--sans);font-weight:500;font-size:13px;letter-spacing:.01em}
.nav svg{width:20px;height:20px}
.cap{font-family:var(--mono);font-size:10px;letter-spacing:.08em;text-transform:uppercase;opacity:.55;flex-basis:100%;margin:-4px 0 0}
footer{padding:40px 0 96px;border-top:1px solid var(--hair);color:var(--dim);font-size:14px}
footer p{max-width:70ch;margin:0 0 8px}
footer code{font-family:var(--mono);font-size:12px}
@media (max-width:860px){.plate{grid-template-columns:1fr;gap:20px}.ways,.tests{grid-template-columns:1fr}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
"""


def board_html():
    parts = []
    for d in DIRECTIONS:
        s = d["slug"]
        chips_d = "".join(f'<figure><div class="chip">{mark_svg(d, "dark", w, f"{s}cd{w}")}</div>'
                          f'<figcaption>{w}</figcaption></figure>' for w in ways_for(d))
        chips_l = "".join(f'<figure><div class="chip">{mark_svg(d, "light", w, f"{s}cl{w}")}</div>'
                          f'<figcaption>{w}</figcaption></figure>' for w in ways_for(d))
        kind = "kept from round one" if d["kept"] else "new this round"
        parts.append(f"""
<section class="plate" id="{s}">
  <div>
    <h2>{d["name"]}</h2>
    <p class="kind{"" if d["kept"] else " new"}">{kind}</p>
    <p>{d["idea"]}</p>
    <p class="note">{d["note"]}</p>
    <p class="sting"><b>Sting, {d["sting"].lower()}.</b> {d["sting_desc"]}</p>
    <p class="file">Design/Logos/{s}/ · video/{s}.mp4</p>
  </div>
  <div>
    <div class="hero" tabindex="0" role="button" aria-label="Replay the {d["name"]} sting">{lockup_svg(d, "dark", d["hero"], f"{s}hero")}<span class="tag">click to replay</span></div>
    <div class="ways">
      <div class="strip dark">{chips_d}</div>
      <div class="strip light">{chips_l}</div>
    </div>
    <div class="tests">
      <div class="strip dark">
        <div class="icon i60">{icon_svg(d, f"{s}i6")}</div>
        <div class="icon i29">{icon_svg(d, f"{s}i2")}</div>
        <div class="nav">{mark_svg(d, "dark", d["hero"], f"{s}nd")}<span>Tessera</span></div>
        <p class="cap">home screen 60 and 29 px, nav bar 20 px</p>
      </div>
      <div class="strip light">
        <div class="icon i60">{icon_svg(d, f"{s}j6")}</div>
        <div class="icon i29">{icon_svg(d, f"{s}j2")}</div>
        <div class="nav">{mark_svg(d, "light", d["hero"], f"{s}nl")}<span>Tessera</span></div>
        <p class="cap">same tests on paper</p>
      </div>
    </div>
  </div>
</section>""")
    css = (CSS.replace("__SW400__", font_uri("Switzer-Regular.otf"))
              .replace("__SW500__", font_uri("Switzer-Medium.otf"))
              .replace("__TE500__", font_uri("Technor-Medium.otf")))
    return f"""<title>Tessera Marks</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Martian+Mono:wght@400;500&display=swap">
<style>{css}{ANIM_CSS}</style>
<div class="frame">
<header>
  <p class="lbl">Tessera · round two · 13 September 2026</p>
  <h1>Six marks for Tessera</h1>
  <p class="dek">Emitter, Mosaic T and Record stay from the first six. Handset, Triad and Cover are new. Every direction now comes in five colourways on both grounds, amber, vermilion, moss and cobalt for whatever is lit, and a plain ink cut for engraving and print. Each has its own sting, a two-second reveal built from the way its mark is made.</p>
  <p class="dek">Click any mark to replay it. Wordmarks are outlines of Technor and Switzer, the faces the app ships, so nothing here is live text.</p>
</header>
{"".join(parts)}
<footer>
  <p>Files: <code>tessera/Design/Logos/</code>, a folder per direction with mark and lockup for every colourway on both grounds, one icon each, and <code>video/</code> with the six stings as MP4 and a reel. Everything is drawn by <code>tessera/Tools/logos.py</code>; the stings are rendered by <code>logos_video.py</code>.</p>
  <p>Amber is Ink.tile (#E8B04B), the app's colour for a lit tessera. Triad's hero is the one exception: its three dies are the app's own red, green and blue, and amber is what they mix to.</p>
</footer>
</div>
<script>{PLAY_JS}</script>
"""


def render_html(d):
    """One sting on a 1920 x 1080 dark frame, for the video renderer."""
    return f"""<meta charset="utf-8"><title>{d["name"]}</title><style>
html,body{{margin:0;background:#0B0A09;width:1920px;height:1080px;overflow:hidden}}
.hero{{position:absolute;inset:0;display:flex;align-items:center;justify-content:center}}
.hero svg{{width:1180px;height:auto;display:block}}
{ANIM_CSS}</style>
<div class="hero run">{lockup_svg(d, "dark", d["hero"], "v")}</div>"""


def sheet_html():
    rows = []
    for d in DIRECTIONS:
        s = d["slug"]
        chips = "".join(f'<div class="c">{mark_svg(d, "dark", w, f"{s}s{w}")}</div>' for w in ways_for(d))
        rows.append(f"""<div class="r"><div class="n">{d["name"]}<small>{"kept" if d["kept"] else "new"}</small></div>
<div class="p d">{lockup_svg(d, "dark", d["hero"], f"{s}sd")}</div>
<div class="p l">{lockup_svg(d, "light", d["hero"], f"{s}sl")}</div>
<div class="p d ic"><div class="i">{icon_svg(d, f"{s}si")}</div></div>
<div class="p d ch">{chips}</div></div>""")
    return f"""<meta charset="utf-8"><title>sheet</title><style>
body{{margin:0;background:#F1ECE2;font-family:-apple-system,Helvetica,Arial,sans-serif;padding:36px 40px}}
.r{{display:grid;grid-template-columns:130px 1fr 1fr 130px 250px;gap:14px;align-items:stretch;margin-bottom:14px}}
.n{{font-size:21px;font-weight:600;color:#17150F;display:flex;flex-direction:column;justify-content:center}}
.n small{{font-size:11px;font-weight:500;letter-spacing:.1em;text-transform:uppercase;color:#7A7466;margin-top:4px}}
.p{{border-radius:8px;padding:24px 28px;display:flex;align-items:center;justify-content:center;min-height:150px}}
.d{{background:#0B0A09}}.l{{background:#F1ECE2;box-shadow:inset 0 0 0 1px rgba(23,21,15,.1)}}
.p svg{{width:100%;height:auto;max-height:96px}}
.ic .i{{width:80px;height:80px;border-radius:18px;overflow:hidden;line-height:0}}.ic .i svg{{width:80px;height:80px}}
.ch{{gap:10px;flex-wrap:wrap;padding:16px}}.ch .c{{width:40px;height:40px;line-height:0}}.ch .c svg{{width:40px;height:40px}}
</style>{"".join(rows)}"""


def main():
    os.makedirs(OUT, exist_ok=True)
    for d in DIRECTIONS:
        s = d["slug"]
        for way in ways_for(d):
            for tn in THEMES:
                write(os.path.join(OUT, s, f"{s}-{way}-{tn}-mark.svg"), mark_svg(d, tn, way, "m"))
                write(os.path.join(OUT, s, f"{s}-{way}-{tn}-lockup.svg"), lockup_svg(d, tn, way, "l"))
        write(os.path.join(OUT, s, f"{s}-icon.svg"), icon_svg(d, "i"))
        write(os.path.join(OUT, "render", f"{s}.html"), render_html(d))
    board = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT, "board.html")
    write(board, board_html())
    write(os.path.join(OUT, "sheet.html"), sheet_html())
    print("wrote", OUT, "and", board)


if __name__ == "__main__":
    main()
