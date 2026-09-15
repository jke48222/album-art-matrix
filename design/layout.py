#!/usr/bin/env python3
"""Where every component goes on the back of Obsidian's face board.

The positions in the Blender model were worked out before the body had folded
wall flanges, so some of them sat under a flange or over a wiring opening. This
places them again against the real constraints and then checks the placement
rather than trusting it: nothing may overlap another component, cover one of
the nine wiring openings or the harness slot, or stray into the band the wall
flanges occupy.

Origin is the centre of the 550 mm face board, X right, Y up, looking at the
back of the board with the picture facing away from you.
"""
import math

BOARD = 550.0
HALF = BOARD / 2
FLANGE_RUN = 230.0        # kept as the exclusion band: the side rails
                          # are thinner than this, so it is conservative
FLANGE_IN = 254.2         # inside face of a flange
PANEL_PITCH = 160.0
OPEN_D = 12.0             # a wiring opening
CHAIN_SLOT = (40.0, 12.0)
HARNESS = (60.0, 14.0)
HARNESS_AT = (0.0, -235.0)
CLEAR = 4.0               # air left around everything

# name, width, height, centre x, centre y, note
PARTS = [
    ("PSU LRS-350-5", 215.0, 115.0, -20.0, -80.0,
     "Terminal strip to the left, toward the gland. Four M4 into the board."),
    ("Raspberry Pi 5", 90.0, 62.0, 205.0, 80.0,
     "Bonnet and cooler stacked on it. M2.5 standoffs, 58 by 49 pattern."),
    ("Bus bar +5V", 137.2, 22.9, -140.0, 232.0, "Above the ground bar."),
    ("Bus bar GND", 137.2, 22.9, -140.0, 195.0, "Below the +5V bar."),
    ("Fuse holders, ten", 160.0, 36.0, 100.0, 210.0,
     "One per panel plus one for the Pi. 10 A blades."),
    ("USB microphone", 22.2, 18.3, 230.0, -200.0, "Points at the room."),
    ("SL22 thermistor", 22.0, 22.0, -200.0, -200.0,
     "In the live feed, before the supply."),
]


def openings():
    """The nine ways through the board, as (x, y, w, h) rectangles."""
    out = []
    k = PANEL_PITCH
    for gy in (-1, 0, 1):
        for gx in (-1, 0, 1):
            x, y = gx * k, gy * k
            if gx == 1:                       # the chain starts get a slot
                out.append((x, y, CHAIN_SLOT[0], CHAIN_SLOT[1]))
            else:
                out.append((x, y, OPEN_D, OPEN_D))
    out.append((HARNESS_AT[0], HARNESS_AT[1], HARNESS[0], HARNESS[1]))
    return out


def _hit(a, b, gap=0.0):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return (abs(ax - bx) * 2 < aw + bw + gap * 2 and
            abs(ay - by) * 2 < ah + bh + gap * 2)


def in_flange(box):
    """True if the box reaches into the band a wall flange lies in."""
    x, y, w, h = box
    x0, x1, y0, y1 = x - w / 2, x + w / 2, y - h / 2, y + h / 2
    for lo, hi in ((y0, y1), (x0, x1)):
        pass
    # the top and bottom flanges: |x| <= 230 and |y| between 254.2 and 275
    if max(abs(y0), abs(y1)) > FLANGE_IN and min(abs(x0), abs(x1)) < FLANGE_RUN:
        return True
    if max(abs(x0), abs(x1)) > FLANGE_IN and min(abs(y0), abs(y1)) < FLANGE_RUN:
        return True
    return False


def check():
    faults = []
    boxes = [(p[3], p[4], p[1], p[2]) for p in PARTS]
    for i, p in enumerate(PARTS):
        b = boxes[i]
        if in_flange(b):
            faults.append("%s sits where a side rail lands" % p[0])
        if max(abs(b[0]) + b[2] / 2, abs(b[1]) + b[3] / 2) > FLANGE_IN:
            faults.append("%s runs past the inside of the body" % p[0])
        for o in openings():
            if _hit(b, o):
                faults.append("%s covers an opening at (%.0f, %.0f)" % (p[0], o[0], o[1]))
        for j in range(i + 1, len(PARTS)):
            if _hit(b, boxes[j], CLEAR):
                faults.append("%s and %s are closer than %.0f mm"
                              % (p[0], PARTS[j][0], CLEAR))
    return faults


def cm(v):
    """Millimetres in, a centimetre label out; the guide is written in cm."""
    t = ("%.1f" if abs(v) >= 100 else "%.2f") % (v / 10.0)
    t = t.rstrip("0").rstrip(".")
    return t if t else "0"


def svg(path, px=760):
    S = BOARD + 40
    sc = px / S
    def X(v):
        return (v + S / 2) * sc
    def Y(v):
        return (S / 2 - v) * sc
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
         'viewBox="0 0 %d %d" font-family="ui-monospace,Menlo,monospace">'
         % (px, px, px, px)]
    o.append('<rect width="%d" height="%d" fill="#ffffff"/>' % (px, px))
    o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#f6f5f2" '
             'stroke="#17181A" stroke-width="1.4"/>'
             % (X(-HALF), Y(HALF), BOARD * sc, BOARD * sc))
    # the flange bands
    for a, b, c, d in ((-FLANGE_RUN, FLANGE_IN, FLANGE_RUN * 2, HALF - FLANGE_IN),
                       (-FLANGE_RUN, -HALF, FLANGE_RUN * 2, HALF - FLANGE_IN)):
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#e2e0da"/>'
                 % (X(a), Y(b + d), c * sc, d * sc))
    for a, b, c, d in ((FLANGE_IN, -FLANGE_RUN, HALF - FLANGE_IN, FLANGE_RUN * 2),
                       (-HALF, -FLANGE_RUN, HALF - FLANGE_IN, FLANGE_RUN * 2)):
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#e2e0da"/>'
                 % (X(a), Y(b + d), c * sc, d * sc))
    # the openings
    for x, y, w, h in openings():
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" rx="%.1f" '
                 'fill="#17181A"/>'
                 % (X(x - w / 2), Y(y + h / 2), w * sc, h * sc, min(w, h) / 2 * sc))
    # the standoff screws
    for sx in (-1, 1):
        for sy in (-1, 1):
            o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="none" '
                     'stroke="#2E5C93" stroke-width="1.2"/>'
                     % (X(sx * 257.5), Y(sy * 257.5), 2.75 * sc))
    # the components
    for name, w, h, x, y, note in PARTS:
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="none" '
                 'stroke="#9C4A46" stroke-width="1.6"/>'
                 % (X(x - w / 2), Y(y + h / 2), w * sc, h * sc))
        # A label above a short box lands on whatever is above it, and a label
        # that runs off the board is worse than none. Tall boxes get it inside;
        # short ones get it beside, on whichever side has the room.
        # Inside whenever the box can hold two lines of type, beside only for
        # the two small parts. The bus bars are short but wide, and a label
        # beside them lands on the fuse block; smaller type inside does not.
        inside = h * sc >= 26 and w * sc >= 120
        if inside:
            tx, anchor = X(x), "middle"
            if h * sc >= 40:
                f1, f2, ty, dy = 10, 9, Y(y) - 2, 11
            else:
                f1, f2, ty, dy = 9.5, 8.5, Y(y) - 3, 11
        elif x > 0:
            f1, f2, dy = 10, 9, 11
            tx, anchor, ty = X(x - w / 2) - 6, "end", Y(y) - 2
        else:
            f1, f2, dy = 10, 9, 11
            tx, anchor, ty = X(x + w / 2) + 6, "start", Y(y) - 2
        o.append('<text x="%.1f" y="%.1f" font-size="%g" fill="#9C4A46" '
                 'text-anchor="%s">%s</text>' % (tx, ty, f1, anchor, name))
        o.append('<text x="%.1f" y="%.1f" font-size="%g" fill="#6E7176" '
                 'text-anchor="%s">%s x %s at (%s, %s) cm</text>'
                 % (tx, ty + dy, f2, anchor, cm(w), cm(h), cm(x), cm(y)))
    o.append('<text x="%.1f" y="%.1f" font-size="10" fill="#6E7176">'
             'Back of the face board. Grey = keep clear, the side rails land here. '
             'Blue = standoff screws.</text>' % (X(-HALF), Y(-HALF) + 16))
    o.append("</svg>")
    open(path, "w").write("".join(o))


if __name__ == "__main__":
    import sys
    f = check()
    for x in f:
        print("  FAULT", x)
    print("%d components, %d faults" % (len(PARTS), len(f)))
    svg(sys.argv[1] if len(sys.argv) > 1 else "obsidian-layout.svg")
