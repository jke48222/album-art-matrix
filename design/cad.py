#!/usr/bin/env python3
"""Flat parts for the four objects, as DXF a cutting service will accept.

Everything here is driven from the same constants the Blender models are built
from, so a part that comes back from SendCutSend fits the object in the
catalogue. Millimetres throughout, R2010 DXF, closed polylines, one part per
file, which is what every service asks for.

Layers, and they matter:

    CUT    the profile and every hole. This is the only layer that gets cut.
    ETCH   laser marking. Panel footprints, fold references, part names. Free
           on steel and aluminium at SendCutSend, and it is the difference
           between assembling nine panels square and eyeballing it.
    BEND   fold lines for the parts that are one blank folded into a tray.
           SendCutSend want these called out; Protocase read them from a
           drawing. Neither is cut.

Run:  python3 design/cad.py --out cad
"""
import argparse
import math
import os

import ezdxf

# ---------------------------------------------------------------- the numbers
# Panels. Verified against the Waveshare P2.5 64x64 drawing.
PANEL = 160.0                  # pitch
PANEL_SHELL = 159.8            # the shell that has to clear its neighbour
COLS = ROWS = 3
FACE = PANEL * COLS            # 480, the picture
CHAIN_COL = 1                  # the right hand column starts each chain

# What the four objects are, measured off the finished models.
OBJECTS = {
    "obsidian":  dict(board=550.0, depth=138.0, glaze=550.0, standoff=True),
    "alabaster": dict(board=560.0, depth=138.0, glaze=492.0, standoff=False),
    "heartwood": dict(board=530.0, depth=104.0, glaze=492.0, standoff=False),
    "chalk":     dict(board=551.0, depth=159.0, glaze=None,  standoff=False),
}

STEEL = 496.0                  # the magnet plate, sized to fit inside all four
WIRE_D = 12.0                  # a panel's harness through the plate
CHAIN_SLOT = (40.0, 12.0)      # the chain start panels need a slot, not a hole
HARNESS = (60.0, 14.0)         # everything drops into the bay through this
FIX_D = 4.5                    # M4 clearance
GLAND_D = 20.5                 # M20 cable gland, the common size
WALL_T = 1.6                   # the wall material, which sets the short walls
FLANGE = 20.0                  # the return that a flange bolts through
RIB = (-180.0, 0.0, 180.0)     # three fixings a side, clear of the corners
# Where a flange's hole actually lands once the wall is folded: half the
# material plus half the flange, in from the outside face. Every flat part that
# bolts to a flange uses this same radius, and takes a 5.5 mm hole rather than
# 4.5, because no press brake lands a fold exactly on the nominal line.
EDGE = WALL_T / 2 + FLANGE / 2
FLANGE_D = 5.5

# Sign standoffs. A 3/4 or 1 inch standoff wants a 13/32 hole, a 1/2 inch one
# wants 5/16. Cutting services hold better than a drill does, so the glazing is
# drawn with the hole in it rather than left to be drilled in acrylic.
STANDOFF_HOLE = {"1/2": 7.94, "3/4": 10.32, "1": 10.32}
STANDOFF_SIZE = "3/4"

BULGE90 = math.tan(math.pi / 8)     # a quarter circle as a polyline bulge


# ------------------------------------------------------------------ primitives
def doc():
    d = ezdxf.new("R2010", setup=True)
    d.header["$INSUNITS"] = 4                      # millimetres
    d.header["$MEASUREMENT"] = 1
    for name, colour in (("CUT", 7), ("ETCH", 3), ("BEND", 5)):
        if name not in d.layers:
            d.layers.add(name, color=colour)
    return d, d.modelspace()


def rect(ms, cx, cy, w, h, r=0.0, layer="CUT"):
    """A rectangle, optionally with radiused corners, as one closed polyline."""
    x0, x1 = cx - w / 2, cx + w / 2
    y0, y1 = cy - h / 2, cy + h / 2
    if r <= 0:
        pts = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    else:
        r = min(r, w / 2, h / 2)
        b = BULGE90
        pts = [(x0 + r, y0, 0, 0, 0), (x1 - r, y0, 0, 0, b),
               (x1, y0 + r, 0, 0, 0), (x1, y1 - r, 0, 0, b),
               (x1 - r, y1, 0, 0, 0), (x0 + r, y1, 0, 0, b),
               (x0, y1 - r, 0, 0, 0), (x0, y0 + r, 0, 0, b)]
    ms.add_lwpolyline(pts, format="xyseb" if r > 0 else "xy",
                      close=True, dxfattribs={"layer": layer})


def hole(ms, cx, cy, d, layer="CUT"):
    ms.add_circle((cx, cy), d / 2, dxfattribs={"layer": layer})


def slot(ms, cx, cy, length, width, layer="CUT"):
    """An obround, drawn along x, with semicircular ends."""
    r = width / 2
    a, b = cx - length / 2 + r, cx + length / 2 - r
    ms.add_lwpolyline(
        [(a, cy - r, 0, 0, 0), (b, cy - r, 0, 0, 1.0),
         (b, cy + r, 0, 0, 0), (a, cy + r, 0, 0, 1.0)],
        format="xyseb", close=True, dxfattribs={"layer": layer})


def line(ms, x0, y0, x1, y1, layer="BEND"):
    ms.add_line((x0, y0), (x1, y1), dxfattribs={"layer": layer})


def label(ms, text, x, y, h=8.0, layer="ETCH"):
    """Deliberately draws nothing.

    Every service reads DXF differently and a TEXT entity is a common reason a
    job is kicked back, so the files carry no text at all. The part name lives
    in the filename, which is what a quote is keyed to. Kept as a call so the
    intent of each part stays readable here.
    """
    return


def orient(ms, w, h=None):
    """One etched triangle at the top edge, so a square part cannot go on 90
    degrees out and take the panel grid with it."""
    h = h or w
    y = h / 2 - 9.0
    ms.add_lwpolyline([(-7.0, y), (7.0, y), (0.0, y - 9.0)],
                      format="xy", close=True, dxfattribs={"layer": "ETCH"})


# ------------------------------------------------------------ shared features
def panel_centres():
    k = (COLS - 1) / 2
    return [((c - k) * PANEL, (r - k) * PANEL) for r in range(ROWS) for c in range(COLS)]


def wiring(ms):
    """One way through for each panel's harness, wider where a chain starts."""
    k = (COLS - 1) / 2
    for r in range(ROWS):
        for c in range(COLS):
            x, y = (c - k) * PANEL, (r - k) * PANEL
            if c == CHAIN_COL + 1:
                slot(ms, x, y, *CHAIN_SLOT)
            else:
                hole(ms, x, y, WIRE_D)


def footprints(ms):
    """Etch where every panel goes. Nine squares at 160 is the whole assembly
    jig, and it costs nothing on a part that is being cut anyway."""
    for x, y in panel_centres():
        rect(ms, x, y, PANEL_SHELL, PANEL_SHELL, layer="ETCH")


def vents(ms, board, bands=(-1, 1), n=6, length=120.0, width=8.0, pitch=20.0):
    """Two fields of slots rather than one long opening: stiffer, and it does
    not need a jigsaw to be believable."""
    for sign in bands:
        y0 = sign * (board / 2 - 92.0)
        for i in range(n):
            y = y0 + (i - (n - 1) / 2) * pitch
            slot(ms, 0.0, y, length, width)


def corners(ms, size, d=FIX_D, inset=18.0):
    for sx in (-1, 1):
        for sy in (-1, 1):
            hole(ms, sx * (size / 2 - inset), sy * (size / 2 - inset), d)


# --------------------------------------------------------------------- parts
def magnet_plate(path):
    """The one part that has to be steel, because the panels' feet are magnets."""
    d, ms = doc()
    rect(ms, 0, 0, STEEL, STEEL, r=6.0)
    wiring(ms)
    slot(ms, 0.0, -(STEEL / 2 - 26.0), *HARNESS)
    corners(ms, STEEL)
    footprints(ms)
    orient(ms, STEEL)
    d.saveas(path)


def face_board(path, name, board, standoff):
    """What the panels' plate and the whole pack hang off."""
    d, ms = doc()
    rect(ms, 0, 0, board, board, r=4.0)
    wiring(ms)
    slot(ms, 0.0, -(board / 2 - 40.0), *HARNESS)
    corners(ms, STEEL)                       # locating holes for the magnet plate
    for k in (-200.0, -100.0, 0.0, 100.0, 200.0):     # the four wall flanges
        e = board / 2 - EDGE
        hole(ms, k, -e, FLANGE_D)
        hole(ms, k, e, FLANGE_D)
        hole(ms, -e, k, FLANGE_D)
        hole(ms, e, k, FLANGE_D)
    if standoff:
        s = (board + FACE) / 4               # the barrel, centred in the mat
        for sx in (-1, 1):
            for sy in (-1, 1):
                hole(ms, sx * s, sy * s, 5.5)   # the standoff's own screw
    footprints(ms)
    orient(ms, board)
    d.saveas(path)


def back_panel(path, name, board):
    d, ms = doc()
    rect(ms, 0, 0, board, board, r=4.0)
    vents(ms, board)
    hole(ms, board / 2 - 46.0, -(board / 2 - 46.0), GLAND_D)
    e = board / 2 - EDGE
    for k in RIB:                            # three a side, matching the flanges
        hole(ms, k, -e, FLANGE_D)
        hole(ms, k, e, FLANGE_D)
        hole(ms, -e, k, FLANGE_D)
        hole(ms, e, k, FLANGE_D)
    # the hanging bar bolts through here, and the two pads at the bottom keep
    # the object parallel to the wall instead of hanging off the cleat alone
    for k in (-110.0, 0.0, 110.0):
        hole(ms, k, 110.0, FLANGE_D)
    for sx in (-1, 1):
        hole(ms, sx * 150.0, -(board / 2 - 30.0), FIX_D)
    orient(ms, board)
    d.saveas(path)


def shell_flat(path, name, board, depth, wall=None):
    """The body as one blank that folds into a tray.

    Four walls with the corners relieved, bend lines on their own layer. This
    is the part that decides whether the object is a box someone made or a box
    someone bought, and it is one file.
    """
    wall = wall or depth
    d, ms = doc()
    h, w = board / 2, wall
    r = 1.6                                   # bend relief, so corners do not tear
    pts = []

    def push(x, y):
        pts.append((x, y))

    # a cross: the base, four walls, corners cut away
    push(-h, -h - w + r); push(-h + r, -h - w)
    push(h - r, -h - w); push(h, -h - w + r)
    push(h, -h + r); push(h + w - r, -h)
    push(h + w, -h + r); push(h + w, h - r)
    push(h + w - r, h); push(h, h - r)
    push(h, h + w - r); push(h - r, h + w)
    push(-h + r, h + w); push(-h, h + w - r)
    push(-h, h - r); push(-h - w + r, h)
    push(-h - w, h - r); push(-h - w, -h + r)
    push(-h - w + r, -h); push(-h, -h + r)
    ms.add_lwpolyline(pts, format="xy", close=True, dxfattribs={"layer": "CUT"})

    for a, b in (((-h, -h), (h, -h)), ((-h, h), (h, h)),
                 ((-h, -h), (-h, h)), ((h, -h), (h, h))):
        line(ms, a[0], a[1], b[0], b[1])

    # the walls carry the vents and the gland, so the back can stay solid
    for sx in (-1, 1):
        for i in range(5):
            slot(ms, sx * (h + w / 2), (i - 2) * 46.0, 30.0, 6.0)
    hole(ms, -(h + w / 2), -150.0, GLAND_D)
    label(ms, "%s SHELL, FOLD 4 x 90 UP, WALL %d" % (name.upper(), wall),
          -h + 16, 0, 7)
    d.saveas(path)


def side_wall(path, name, board, wall, flange=FLANGE, long=True):
    """One wall of the body, with a flange along the top that bolts flat to the
    back of the face board.

    The one piece shell is the better object, but a tray with flanges on all
    four sides is a bend a lot of laser shops will not take, because the last
    fold traps the tooling. Protocase form enclosures like that every day;
    SendCutSend would rather cut four of these and let you bolt them. One bend
    each, no argument.
    """
    d, ms = doc()
    L = board if long else board - 2 * WALL_T
    h = wall + 2 * flange                     # front flange, wall, rear flange
    top = h / 2 - flange
    # The flanges stop short of the ends. Run them the full length and they
    # cover the four standoff screws at the corners of the mat, and there is
    # nowhere to put a nut. Stopping at 230 also relieves the bend at the
    # corners, which is what you would do anyway.
    fl = 230.0
    ms.add_lwpolyline(
        [(-L / 2, -top), (-fl, -top), (-fl, -h / 2), (fl, -h / 2), (fl, -top),
         (L / 2, -top), (L / 2, top), (fl, top), (fl, h / 2), (-fl, h / 2),
         (-fl, top), (-L / 2, top)],
        format="xy", close=True, dxfattribs={"layer": "CUT"})
    line(ms, -fl, top, fl, top)               # folds up to the face board
    line(ms, -fl, -top, fl, -top)             # folds in for the back panel
    for k in (-200.0, -100.0, 0.0, 100.0, 200.0):     # into the face board
        hole(ms, k, h / 2 - flange / 2, FIX_D)
    for k in RIB:                             # the back panel screws into these
        hole(ms, k, -(h / 2 - flange / 2), FIX_D)
    # the corner brackets, 50 mm apart so one bracket serves any wall depth
    mid = 0.0
    for sx in (-1, 1):
        for k in (mid - 25.0, mid + 25.0):
            hole(ms, sx * (L / 2 - 11.0), k, FLANGE_D)
    for i in range(5):                        # vents
        slot(ms, (i - 2) * 60.0, mid + 34.0, 30.0, 6.0)
    d.saveas(path)


def corner_bracket(path, wall, leg=22.0):
    """An L that ties two walls together, holes matched to theirs."""
    d, ms = doc()
    L = 74.0                                  # holds the two holes 50 apart
    rect(ms, 0, 0, leg * 2, L, r=2.0)
    line(ms, 0, -L / 2, 0, L / 2)
    for sx in (-1, 1):
        for k in (-25.0, 25.0):
            hole(ms, sx * (leg - 11.0), k, FLANGE_D)
    d.saveas(path)


def glazing(path, name, size, standoff, board):
    d, ms = doc()
    rect(ms, 0, 0, size, size, r=3.0)
    if standoff:
        s = (board + FACE) / 4
        for sx in (-1, 1):
            for sy in (-1, 1):
                hole(ms, sx * s, sy * s, STANDOFF_HOLE[STANDOFF_SIZE])
    d.saveas(path)


def liner(path, window=484.0, ret=6.0):
    """Heartwood's black anodised reveal: a picture-frame blank that folds back."""
    d, ms = doc()
    o = window + 2 * ret
    rect(ms, 0, 0, o, o, r=2.0)
    rect(ms, 0, 0, window, window)
    for s in (-1, 1):
        line(ms, -window / 2, s * window / 2, window / 2, s * window / 2)
        line(ms, s * window / 2, -window / 2, s * window / 2, window / 2)
    label(ms, "HEARTWOOD LINER, FOLD 4 x 90 BACK", -o / 2 + 14, o / 2 - 14, 6)
    d.saveas(path)


def cove_profile(path, section=32.0):
    """Alabaster's section, 1:1, for a router template or a shaper knife."""
    d, ms = doc()
    r = section
    pts = [(0.0, 0.0, 0, 0, 0), (r, 0.0, 0, 0, BULGE90),
           (0.0, r, 0, 0, 0)]
    ms.add_lwpolyline(pts, format="xyseb", close=True, dxfattribs={"layer": "CUT"})
    label(ms, "ALABASTER COVE SECTION R%d, 1:1" % section, r + 6, r / 2, 5)
    d.saveas(path)


def key_jig(path, frame_w=16.0, pin=3.2):
    """A drilling template for Heartwood's brass corner keys."""
    d, ms = doc()
    L = 90.0
    rect(ms, 0, 0, L, frame_w + 8.0, r=2.0)
    for i in (-1, 0, 1):
        hole(ms, i * 22.0, 0.0, pin)
    line(ms, -L / 2, 0, L / 2, 0, layer="ETCH")
    label(ms, "HEARTWOOD KEY JIG, 3 x %.1f AT 22" % pin, -L / 2 + 4,
          frame_w / 2 + 6, 4)
    d.saveas(path)


def zbar(path, name, board, wall=38.0):
    """A folded Z, which is the metal way to do a French cleat."""
    d, ms = doc()
    L = min(board - 80.0, 360.0)
    rect(ms, 0, 0, L, wall * 2, r=2.0)
    line(ms, -L / 2, 0, L / 2, 0)
    for i in (-1, 0, 1):
        hole(ms, i * (L / 3 - 10), -wall / 2, 5.5)
        hole(ms, i * (L / 3 - 10), wall / 2, 5.5)
    label(ms, "%s Z BAR, FOLD 1 x 90, PAIR" % name.upper(), -L / 2 + 8, wall + 6, 5)
    d.saveas(path)


# ---------------------------------------------------------------------- build
def main():
    global STANDOFF_SIZE
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="cad")
    ap.add_argument("--standoff", default=STANDOFF_SIZE, choices=list(STANDOFF_HOLE))
    args = ap.parse_args()
    STANDOFF_SIZE = args.standoff
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)

    made = []

    def p(n):
        made.append(n)
        return os.path.join(out, n)

    magnet_plate(p("common-magnet-plate-496.dxf"))
    cove_profile(p("alabaster-cove-section.dxf"))
    key_jig(p("heartwood-key-jig.dxf"))

    for name, o in OBJECTS.items():
        face_board(p("%s-face-board.dxf" % name), name, o["board"], o["standoff"])
        back_panel(p("%s-back-panel.dxf" % name), name, o["board"])
        shell_flat(p("%s-shell-flat.dxf" % name), name, o["board"], o["depth"],
                   wall=o["depth"] - 12.0)
        zbar(p("%s-z-bar.dxf" % name), name, o["board"])
        side_wall(p("%s-side-wall-long.dxf" % name), name, o["board"],
                  o["depth"] - 12.0, long=True)
        side_wall(p("%s-side-wall-short.dxf" % name), name, o["board"],
                  o["depth"] - 12.0, long=False)
        corner_bracket(p("%s-corner-bracket.dxf" % name), o["depth"] - 12.0)
        if o["glaze"]:
            glazing(p("%s-glazing.dxf" % name), name, o["glaze"], o["standoff"],
                    o["board"])
    liner(p("heartwood-liner.dxf"))

    for n in sorted(made):
        print("  %-34s %6d bytes" % (n, os.path.getsize(os.path.join(out, n))))
    print("%d files in %s" % (len(made), out))


if __name__ == "__main__":
    main()
