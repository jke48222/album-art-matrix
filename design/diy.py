#!/usr/bin/env python3
"""Drawings for building Obsidian out of plywood with a drill.

Two of them. The cutting plan says what to have cut off a 2 by 4 foot panel at
the store, since every cut here is straight and none of them are yours to make.
The drilling plan is the face board with every hole on it, dimensioned from the
board's own centre, plus where the steel strips land.

Checked, not drawn by eye: the nesting is verified to fit inside the panel and
not overlap itself, and every drilled hole is verified clear of every other.
"""
import math

MM_FT = 304.8
# The project panel is sold as 2 x 4 ft but cut to 23.75 x 47.75 in, which is
# what the nesting has to fit inside. Home Depot lists these as the actual size.
PANEL_W, PANEL_L = 23.75 * 25.4, 47.75 * 25.4     # 603 x 1213
BOARD = 550.0
RAIL_D = 63.5                                # 2-1/2 in, the side rails
PLY = 11.9                                   # MEASURED  a "1/2 in" project panel
                                             # is really 0.47 in. The short
                                             # rails are BOARD - 2 * PLY, so
                                             # this is the number that decides
                                             # whether the corners close.
BACK_PLY = 6.35                              # 1/4 in
VENT = 22.0                                  # the gap between back strips
PITCH = 160.0
OPEN_D = 12.0
CHAIN_D = 25.0                               # a 1 in Forstner where a chain starts
HARNESS_D = 25.0
STANDOFF_AT = 257.5
STEEL_ROWS = (-233.0, -80.0, 80.0, 233.0)    # under the magnet feet
STEEL_W = 50.8                               # 2 in
# 460, not the full width. The feet only reach x = 205, and a full width strip
# runs under the two top and two bottom standoff screws.
STEEL_LEN = 460.0
FOOT_X = 45.0
FOOT_Y = 73.0                                # the M3 points a foot uses
BACK_STRIP = (BOARD - 2 * VENT) / 3          # three strips, two vents

STEEL_W_SHEET, STEEL_L_SHEET = 12 * 25.4, 24 * 25.4   # the 12 x 24 in sheet
PLATE = (84.0, 18.0)           # ONE inlet strip. Two of them, with the module's
                               # body passing between, so there is no internal
                               # cutout: snips cannot start a hole in the middle.
CROSS = 550.0                  # where the first crosscut falls
PADS_W, PADS_L = 40.0, 4 * 40.0 + 300.0   # one strip yields four pads and the shim

INK, GREY, HAIR, RED, BLUE = "#17181A", "#6E7176", "#D8D7D3", "#9C4A46", "#2E5C93"


def cm(v):
    """Millimetres in, a centimetre label out. The guide is written in cm.
    One decimal on anything over 10 cm, two below, because nobody saws to a
    tenth of a millimetre but a board thickness is worth two figures."""
    t = ("%.1f" if v >= 100 else "%.2f") % (v / 10.0)
    t = t.rstrip("0").rstrip(".")
    return t if t else "0"


# --------------------------------------------------------------- the cut plan
def half_inch_parts():
    """Everything that comes off the 1/2 in panel."""
    return [
        ("Face board", BOARD, BOARD, 1),
        ("Side rail, long", BOARD, RAIL_D, 2),
        ("Side rail, short", BOARD - 2 * PLY, RAIL_D, 2),
    ]


def nest():
    """The parts laid out the way section 3 tells you to cut them.

    One crosscut at 550 splits the panel. The face board comes out of the short
    piece; four rail strips and the pads-and-shim strip are ripped along the
    length of the long piece and then cut to length, so each strip carries an
    offcut at its far end.
    """
    rest = PANEL_L - CROSS                      # what is left after the crosscut
    placed = [("Face board", 0.0, 0.0, BOARD, BOARD)]
    y = 0.0
    for name, finished in (("Side rail, long", BOARD),
                           ("Side rail, long", BOARD),
                           ("Side rail, short", BOARD - 2 * PLY),
                           ("Side rail, short", BOARD - 2 * PLY)):
        placed.append((name, CROSS, y, rest, RAIL_D, finished))
        y += RAIL_D
    placed.append(("Pads and shim", CROSS, y, rest, PADS_W, PADS_L))
    return placed, y + PADS_W, rest


def check_nest():
    placed, across, rest = nest()
    faults = []
    if BOARD > PANEL_W:
        faults.append("the face board is wider than the panel")
    if across > PANEL_W:
        faults.append("the strips need %.0f across and the panel is %.0f"
                      % (across, PANEL_W))
    for p in placed:
        if len(p) == 6 and p[5] > p[3]:
            faults.append("%s is %.0f long and its blank is %.0f"
                          % (p[0], p[5], p[3]))
    for i, a in enumerate(placed):
        for b in placed[i + 1:]:
            if (a[1] < b[1] + b[3] and b[1] < a[1] + a[3] and
                    a[2] < b[2] + b[4] and b[2] < a[2] + a[4]):
                faults.append("%s overlaps %s" % (a[0], b[0]))
    return faults, across


def back_parts():
    """The three back strips, all of them off one crosscut piece."""
    placed, y = [], 0.0
    for i in range(3):
        placed.append(("Back strip %d" % (i + 1), 0.0, y, CROSS, BACK_STRIP))
        y += BACK_STRIP
    return placed, y


def check_back():
    placed, across = back_parts()
    faults = []
    if across > PANEL_W:
        faults.append("the back strips need %.0f across and the panel is %.0f"
                      % (across, PANEL_W))
    if CROSS > PANEL_L:
        faults.append("the crosscut is longer than the panel")
    made = 3 * BACK_STRIP + 2 * VENT
    if abs(made - BOARD) > 0.05:
        faults.append("three strips and two vents make %.1f, not %.0f" % (made, BOARD))
    return faults, across


def check_steel():
    """The four magnet strips and the inlet plate, out of one 12 x 24 sheet."""
    faults = []
    across = 4 * STEEL_W + 2 * PLATE[1]
    if across > STEEL_W_SHEET:
        faults.append("the steel pieces need %.0f across and the sheet is %.0f"
                      % (across, STEEL_W_SHEET))
    if STEEL_LEN > STEEL_L_SHEET:
        faults.append("a strip is longer than the sheet")
    return faults, across


# ------------------------------------------------------------------- drawing
def _svg(w, h, body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" '
            'width="%d" font-family="ui-monospace,Menlo,monospace">%s</svg>'
            % (w, h, w, "".join(body)))


def _part(o, x, y, w, h, sc, label, size, waste=0.0):
    """One part on a sheet: its blank, the offcut shaded, and a label."""
    o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#fff" '
             'stroke="%s" stroke-width="1.2"/>'
             % (x * sc, y * sc, w * sc, h * sc, RED))
    if waste:
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s" '
                 'stroke="none"/>'
                 % ((x + w - waste) * sc, y * sc, waste * sc, h * sc, HAIR))
    tx, ty = x * sc + 5, y * sc + 13
    if h * sc < 34:                              # a thin strip: one line, inline
        o.append('<text x="%.1f" y="%.1f" font-size="10.5" fill="%s">%s  %s</text>'
                 % (tx, y * sc + h * sc / 2 + 4, RED, label, size))
    else:
        o.append('<text x="%.1f" y="%.1f" font-size="11" fill="%s">%s</text>'
                 % (tx, ty, RED, label))
        o.append('<text x="%.1f" y="%.1f" font-size="10" fill="%s">%s</text>'
                 % (tx, ty + 14, GREY, size))


def cut_plan(path, px=900):
    placed, across, rest = nest()
    sc = px / PANEL_L
    H = PANEL_W * sc
    o = ['<rect width="%d" height="%.0f" fill="#ffffff"/>' % (px, H),
         '<rect x="0" y="0" width="%d" height="%.0f" fill="#F6F5F2" stroke="%s" '
         'stroke-width="1.4"/>' % (px, H, INK)]
    o.append('<rect x="0" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
             % (BOARD * sc, CROSS * sc, (PANEL_W - BOARD) * sc, HAIR))
    for p in placed:
        name, x, y, w, h = p[:5]
        if len(p) == 6:
            fin = p[5]
            _part(o, x, y, w, h, sc, name,
                  "%s cm wide, cut to %s cm" % (cm(h), cm(fin)), w - fin)
        else:
            _part(o, x, y, w, h, sc, name, "%s x %s cm" % (cm(w), cm(h)))
    o.append('<path d="M%.1f,0 L%.1f,%.0f" stroke="%s" stroke-width="1.6" '
             'stroke-dasharray="8 5"/>' % (CROSS * sc, CROSS * sc, H, BLUE))
    o.append('<text x="%.1f" y="%.0f" font-size="10.5" fill="%s" '
             'text-anchor="start">crosscut here first, %s cm from the end</text>'
             % (CROSS * sc + 8, H - 30, BLUE, cm(CROSS)))
    o.append('<text x="6" y="%.0f" font-size="10.5" fill="%s">1/2 in panel, which '
             'really measures 23-3/4 x 47-3/4 in. Grey is offcut. Rip each strip '
             'full length first, then cut it to length.</text>' % (H - 9, GREY))
    open(path, "w").write(_svg(px, int(H), o))


def back_plan(path, px=900):
    placed, across = back_parts()
    sc = px / PANEL_L
    H = PANEL_W * sc
    o = ['<rect width="%d" height="%.0f" fill="#ffffff"/>' % (px, H),
         '<rect x="0" y="0" width="%d" height="%.0f" fill="#F6F5F2" stroke="%s" '
         'stroke-width="1.4"/>' % (px, H, INK)]
    o.append('<rect x="0" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
             % (across * sc, CROSS * sc, (PANEL_W - across) * sc, HAIR))
    for name, x, y, w, h in placed:
        _part(o, x, y, w, h, sc, name, "%s x %s cm" % (cm(w), cm(h)))
    o.append('<path d="M%.1f,0 L%.1f,%.0f" stroke="%s" stroke-width="1.6" '
             'stroke-dasharray="8 5"/>' % (CROSS * sc, CROSS * sc, H, BLUE))
    o.append('<text x="%.1f" y="%.0f" font-size="10.5" fill="%s" '
             'text-anchor="start">crosscut here first, %s cm from the end</text>'
             % (CROSS * sc + 8, H - 30, BLUE, cm(CROSS)))
    o.append('<text x="%.1f" y="%.0f" font-size="11" fill="%s" '
             'text-anchor="middle">everything past the crosscut is spare</text>'
             % ((CROSS + (PANEL_L - CROSS) / 2) * sc, H / 2, GREY))
    o.append('<text x="6" y="%.0f" font-size="10.5" fill="%s">1/4 in panel, same '
             '23-3/4 x 47-3/4 in. Three strips of %s cm plus the two %s cm vents '
             'between them make the %s cm back.</text>'
             % (H - 9, GREY, cm(BACK_STRIP), cm(VENT), cm(BOARD)))
    open(path, "w").write(_svg(px, int(H), o))


def steel_plan(path, px=900):
    sc = px / STEEL_L_SHEET
    H = STEEL_W_SHEET * sc
    o = ['<rect width="%d" height="%.0f" fill="#ffffff"/>' % (px, H),
         '<rect x="0" y="0" width="%d" height="%.0f" fill="#EEF1F3" stroke="%s" '
         'stroke-width="1.4"/>' % (px, H, INK)]
    y = 0.0
    for i in range(4):
        _part(o, 0.0, y, STEEL_LEN, STEEL_W, sc, "Magnet strip %d" % (i + 1),
              "%s x %s cm" % (cm(STEEL_LEN), cm(STEEL_W)))
        y += STEEL_W
    for i in range(2):
        _part(o, 0.0, y, PLATE[0], PLATE[1], sc, "Inlet strip %d" % (i + 1),
              "%s x %s cm" % (cm(PLATE[0]), cm(PLATE[1])))
        y += PLATE[1]
    o.append('<text x="6" y="%.0f" font-size="10.5" fill="%s">12 x 24 in steel '
             'sheet. Six pieces off it, every cut straight, all with the tin '
             'snips. Everything blank is spare.</text>' % (H - 9, GREY))
    open(path, "w").write(_svg(px, int(H), o))


# ------------------------------------------------------------- the drill plan
def holes():
    """Every hole in the face board, as (x, y, diameter, what)."""
    out = []
    k = 1
    # All nine the same size. The chain starts need room for a ribbon plug, but
    # which column they fall in depends on which way the chain runs, and the
    # drill plan is drawn from the front while the layout is drawn from the
    # back. Making all nine 2.5 cm means it cannot be drilled on the wrong side.
    for gy in (-1, 0, 1):
        for gx in (-1, 0, 1):
            out.append((gx * PITCH, gy * PITCH, CHAIN_D, "panel opening"))
    out.append((110.0, -190.0, HARNESS_D, "routing to the bay"))
    for sx in (-1, 1):
        for sy in (-1, 1):
            out.append((sx * STANDOFF_AT, sy * STANDOFF_AT, 3.5, "standoff screw"))
    return out


def check_holes():
    faults = []
    hs = holes()
    for i, a in enumerate(hs):
        if max(abs(a[0]) + a[2] / 2, abs(a[1]) + a[2] / 2) > BOARD / 2 - 6:
            faults.append("a %s hole is too near the edge" % a[3])
        for b in hs[i + 1:]:
            d = math.hypot(a[0] - b[0], a[1] - b[1])
            if d < (a[2] + b[2]) / 2 + 6:
                faults.append("%s and %s holes are %.0f mm apart" % (a[3], b[3], d))
    # the rails land on the board's edge: nothing may sit under them
    for x, y, dia, what in hs:
        if max(abs(x), abs(y)) + dia / 2 > BOARD / 2 - PLY - 2 and what != "standoff screw":
            faults.append("a %s hole is under a side rail" % what)
    # a foot must land on steel, in both axes
    for gy in (-1, 0, 1):
        for sy in (-1, 1):
            fy = gy * PITCH + sy * FOOT_Y
            if not any(abs(fy - r) <= STEEL_W / 2 - 6 for r in STEEL_ROWS):
                faults.append("a magnet foot row at y = %.0f has no steel" % fy)
    for gx in (-1, 0, 1):
        for sx in (-1, 1):
            fx = gx * PITCH + sx * FOOT_X
            if abs(fx) + 6 > STEEL_LEN / 2:
                faults.append("a foot at x = %.0f is off the end of the steel" % fx)
    # and no hole may be drilled through a strip
    for x, y, dia, what in hs:
        for r in STEEL_ROWS:
            if (abs(y - r) < (STEEL_W + dia) / 2
                    and abs(x) < (STEEL_LEN + dia) / 2):
                faults.append("a %s hole at (%.0f, %.0f) is under the steel at "
                              "y = %+.0f" % (what, x, y, r))
    return faults


# ------------------------------------------------------------------- drawing
def drill_plan(path, px=620):
    S = BOARD + 90
    sc = px / S
    def X(v):
        return (v + S / 2) * sc
    def Y(v):
        return (S / 2 - v) * sc
    o = ['<rect width="%d" height="%d" fill="#ffffff"/>' % (px, px)]
    o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#F6F5F2" '
             'stroke="%s" stroke-width="1.4"/>'
             % (X(-275), Y(275), BOARD * sc, BOARD * sc, INK))
    # the steel strips
    for r in STEEL_ROWS:
        o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="#DEDCD6" '
                 'stroke="%s" stroke-dasharray="4 3" stroke-width="1"/>'
                 % (X(-STEEL_LEN / 2), Y(r + STEEL_W / 2), STEEL_LEN * sc,
                    STEEL_W * sc, GREY))
        o.append('<text x="%.1f" y="%.1f" font-size="8.5" fill="%s">steel, y = %s%s</text>'
                 % (X(-STEEL_LEN / 2 + 5), Y(r) + 3, GREY,
                    "+" if r > 0 else "-", cm(abs(r))))
    # where the rails land
    o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="none" '
             'stroke="%s" stroke-dasharray="6 4" stroke-width="1"/>'
             % (X(-275 + PLY), Y(275 - PLY), (BOARD - 2 * PLY) * sc,
                (BOARD - 2 * PLY) * sc, BLUE))
    # the picture
    o.append('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="none" '
             'stroke="%s" stroke-width="0.8" stroke-dasharray="2 3"/>'
             % (X(-240), Y(240), 480 * sc, 480 * sc, HAIR))
    for x, y, dia, what in holes():
        col = BLUE if what == "standoff screw" else INK
        o.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="none" stroke="%s" '
                 'stroke-width="1.3"/>' % (X(x), Y(y), dia / 2 * sc, col))
        o.append('<text x="%.1f" y="%.1f" font-size="7.5" fill="%s" '
                 'text-anchor="middle">%s</text>'
                 % (X(x), Y(y) - dia / 2 * sc - 3, col, cm(dia)))
    for v in (-320, 320):
        pass
    o.append('<text x="%.1f" y="%.1f" font-size="9" fill="%s">Face board, seen '
             'from the front. Grey = steel strips glued on. Blue dashes = where '
             'the rails land.</text>' % (X(-275), Y(-275) + 22, GREY))
    o.append('<text x="%.1f" y="%.1f" font-size="9" fill="%s">Numbers are hole '
             'diameters in cm. Positions are on a 16 cm grid from the centre.</text>'
             % (X(-275), Y(-275) + 36, GREY))
    open(path, "w").write(_svg(px, px, o))


if __name__ == "__main__":
    import sys
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    f1, across = check_nest()
    f2 = check_holes()
    f3, st_across = check_steel()
    f4, bk_across = check_back()
    for x in f1 + f2 + f3 + f4:
        print("  FAULT", x)
    print("1/2 in uses %.0f of %.0f across; 1/4 in uses %.0f; steel uses %.0f of "
          "%.0f; %d faults" % (across, PANEL_W, bk_across, st_across,
                               STEEL_W_SHEET, len(f1) + len(f2) + len(f3) + len(f4)))
    cut_plan(out + "/obsidian-diy-cuts.svg")
    back_plan(out + "/obsidian-diy-back.svg")
    steel_plan(out + "/obsidian-diy-steel.svg")
    drill_plan(out + "/obsidian-diy-drill.svg")
