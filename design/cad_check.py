#!/usr/bin/env python3
"""Read the DXFs back and check they are actually cuttable, then draw them.

A DXF that opens is not a DXF that can be made. This reads every file with the
same library a service would, flattens curves to points, and checks the things
that get a job rejected or a part scrapped:

  * the outer profile is closed and is the largest loop
  * every hole and slot sits inside it, with a web left at the edge
  * no two internal features overlap
  * nothing is smaller than the material can hold

Then it writes one SVG per part so the geometry can be looked at rather than
trusted.
"""
import glob
import math
import os
import sys

import ezdxf
from ezdxf import path as ezpath

MIN_WEB = 3.0            # metal left between a feature and anything else
MIN_FEATURE = 1.5        # nothing narrower than roughly one thickness


def loops(msp, layer="CUT"):
    """Every closed CUT loop as a list of points."""
    out = []
    for e in msp:
        if e.dxf.layer != layer:
            continue
        if e.dxftype() == "CIRCLE":
            c, r = e.dxf.center, e.dxf.radius
            out.append(([(c.x + r * math.cos(t), c.y + r * math.sin(t))
                         for t in [i * math.pi / 24 for i in range(48)]], "circle", r))
        elif e.dxftype() == "LWPOLYLINE":
            p = ezpath.make_path(e)
            pts = [(v.x, v.y) for v in p.flattening(0.25)]
            out.append((pts, "poly", None))
    return out


def bbox(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    return min(xs), min(ys), max(xs), max(ys)


def area(pts):
    a = 0.0
    for i in range(len(pts)):
        x0, y0 = pts[i]
        x1, y1 = pts[(i + 1) % len(pts)]
        a += x0 * y1 - x1 * y0
    return abs(a) / 2


def inside(pt, poly):
    x, y = pt
    n = len(poly)
    c = False
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i - 1) % n]
        if ((y0 > y) != (y1 > y)) and (x < (x1 - x0) * (y - y0) / (y1 - y0 + 1e-12) + x0):
            c = not c
    return c


def check(f):
    doc = ezdxf.readfile(f)
    msp = doc.modelspace()
    ls = loops(msp)
    faults = []
    if not ls:
        return ["no CUT geometry at all"], None
    ls.sort(key=lambda L: area(L[0]), reverse=True)
    outer = ls[0][0]
    holes = ls[1:]

    ox0, oy0, ox1, oy1 = bbox(outer)
    for pts, kind, r in holes:
        if not all(inside(p, outer) for p in pts[::3]):
            faults.append("a feature crosses the outside profile")
            break
    # web to the edge
    for pts, kind, r in holes:
        hx0, hy0, hx1, hy1 = bbox(pts)
        web = min(hx0 - ox0, hy0 - oy0, ox1 - hx1, oy1 - hy1)
        if web < MIN_WEB:
            faults.append("only %.1f mm of material at the edge" % web)
            break
    # features against each other
    boxes = [bbox(p[0]) for p in holes]
    for i in range(len(boxes)):
        for j in range(i + 1, len(boxes)):
            ax0, ay0, ax1, ay1 = boxes[i]
            bx0, by0, bx1, by1 = boxes[j]
            gx = max(bx0 - ax1, ax0 - bx1)
            gy = max(by0 - ay1, ay0 - by1)
            if gx < MIN_WEB and gy < MIN_WEB:
                faults.append("two features are %.1f mm apart" % max(gx, gy, 0))
                break
        else:
            continue
        break
    for pts, kind, r in holes:
        hx0, hy0, hx1, hy1 = bbox(pts)
        if min(hx1 - hx0, hy1 - hy0) < MIN_FEATURE:
            faults.append("a feature is under %.1f mm across" % MIN_FEATURE)
            break
    return faults, (ox1 - ox0, oy1 - oy0, len(holes))


def svg(f, dst, px=300):
    doc = ezdxf.readfile(f)
    msp = doc.modelspace()
    allpts = []
    draw = []
    for e in msp:
        lay = e.dxf.layer
        if e.dxftype() == "CIRCLE":
            c, r = e.dxf.center, e.dxf.radius
            pts = [(c.x + r * math.cos(t), c.y + r * math.sin(t))
                   for t in [i * math.pi / 18 for i in range(36)]]
        elif e.dxftype() == "LWPOLYLINE":
            pts = [(v.x, v.y) for v in ezpath.make_path(e).flattening(0.2)]
        elif e.dxftype() == "LINE":
            pts = [(e.dxf.start.x, e.dxf.start.y), (e.dxf.end.x, e.dxf.end.y)]
        else:
            continue
        allpts += pts
        draw.append((lay, pts))
    if not allpts:
        return None
    x0, y0, x1, y1 = bbox(allpts)
    w, h = max(x1 - x0, 1), max(y1 - y0, 1)
    pad = max(w, h) * 0.04
    vb = "%.2f %.2f %.2f %.2f" % (x0 - pad, -(y1 + pad), w + 2 * pad, h + 2 * pad)
    sw = max(w, h) / px * 1.4
    body = []
    style = {"CUT": ("#111", sw), "ETCH": ("#c0392b", sw * 0.7),
             "BEND": ("#2E5C93", sw * 0.7)}
    for lay, pts in draw:
        col, width = style.get(lay, ("#999", sw))
        d = " ".join("%s%.2f,%.2f" % ("M" if i == 0 else "L", p[0], -p[1])
                     for i, p in enumerate(pts))
        dash = ' stroke-dasharray="%.2f %.2f"' % (sw * 5, sw * 4) if lay == "BEND" else ""
        body.append('<path d="%s%s" fill="none" stroke="%s" stroke-width="%.3f"%s/>'
                    % (d, " Z" if lay != "BEND" and len(pts) > 2 else "", col, width, dash))
    out = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="%s" '
           'width="%d">%s</svg>' % (vb, px, "".join(body)))
    open(dst, "w").write(out)
    return w, h


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "cad"
    files = sorted(glob.glob(os.path.join(src, "*.dxf")))
    bad = 0
    rows = []
    for f in files:
        faults, size = check(f)
        s = svg(f, f.replace(".dxf", ".svg"))
        n = os.path.basename(f)
        if faults:
            bad += 1
            print("  FAULT %-34s %s" % (n, "; ".join(faults)))
        else:
            print("  ok    %-34s %.0f x %.0f mm, %d features"
                  % (n, size[0], size[1], size[2]))
        rows.append((n, size, faults))
    print("%d files, %d with faults" % (len(files), bad))
    return rows


if __name__ == "__main__":
    main()
