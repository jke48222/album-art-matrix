#!/usr/bin/env python3
"""Turn each DXF back into a description precise enough to rebuild it from words.

Written for SendCutSend's part builder, but it is really just the part restated
in the only form that cannot be misread: origin at the centre of the part, X to
the right, Y up, every feature with a diameter and a coordinate. Read straight
out of the DXF, so the words and the file cannot drift apart.

Features are recognised rather than dumped. A closed polyline with four ninety
degree bulges is a rounded rectangle, two half circle bulges is a slot, and
nine identical holes on a 160 mm grid get described as a grid rather than as
nine coordinates.
"""
import glob
import math
import os

import ezdxf

TOL = 0.05
Q = 0.41421356          # bulge of a 90 degree arc
SEMI = 1.0              # bulge of a 180 degree arc


def _n(v):
    """A number the way it should be read aloud."""
    return ("%.2f" % v).rstrip("0").rstrip(".")


def classify(e):
    """One entity as (kind, dict) or None."""
    t = e.dxftype()
    if t == "CIRCLE":
        return ("hole", dict(x=e.dxf.center.x, y=e.dxf.center.y,
                             d=e.dxf.radius * 2, layer=e.dxf.layer))
    if t == "LINE":
        return ("line", dict(x0=e.dxf.start.x, y0=e.dxf.start.y,
                             x1=e.dxf.end.x, y1=e.dxf.end.y, layer=e.dxf.layer))
    if t != "LWPOLYLINE":
        return None
    pts = list(e.get_points("xyb"))
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    bulges = [p[2] for p in pts]
    big = [b for b in bulges if abs(b) > TOL]
    common = dict(x=cx, y=cy, w=w, h=h, layer=e.dxf.layer, n=len(pts))
    if len(pts) == 4 and len(big) == 2 and all(abs(abs(b) - SEMI) < TOL for b in big):
        width = min(w, h)
        return ("slot", dict(common, length=max(w, h) + width, width=width,
                             vertical=h > w))
    if len(pts) == 8 and len(big) == 4 and all(abs(abs(b) - Q) < TOL for b in big):
        # the straight run between two arcs gives the radius back
        r = (w - max(abs(pts[i][0] - pts[i + 1][0]) for i in range(0, 7, 2))) / 2
        return ("rrect", dict(common, r=abs(r)))
    if len(pts) == 4 and not big:
        return ("rect", common)
    if len(pts) == 3 and len(big) == 1:
        return ("quarter", dict(common, r=max(w, h)))
    if len(pts) == 12 and not big:
        run = max(abs(v) for v in xs if abs(v) < max(map(abs, xs)) - 0.5)
        band = h / 2 - max(abs(v) for v in ys if abs(v) < max(map(abs, ys)) - 0.5)
        return ("notched", dict(common, run=run * 2, band=band))
    if len(pts) == 20 and not big:
        base = 2 * min(abs(v) for v in xs)
        return ("cross", dict(common, base=base, flange=(w - base) / 2))
    return ("outline", common)


def group_holes(holes):
    """Nine holes on a grid is a grid, not nine holes."""
    out = []
    by_d = {}
    for h in holes:
        by_d.setdefault(round(h["d"], 2), []).append(h)
    for d, hs in sorted(by_d.items()):
        xs = sorted({round(h["x"], 1) for h in hs})
        ys = sorted({round(h["y"], 1) for h in hs})
        grid = len(hs) == len(xs) * len(ys) and len(xs) > 1 and len(ys) > 1
        even_x = grid and len({round(xs[i + 1] - xs[i], 1) for i in range(len(xs) - 1)}) == 1
        even_y = grid and len({round(ys[i + 1] - ys[i], 1) for i in range(len(ys) - 1)}) == 1
        if grid:
            out.append("%d holes %s mm diameter at every combination of "
                       "x = %s and y = %s mm"
                       % (len(hs), _n(d),
                          ", ".join(_n(v) for v in xs), ", ".join(_n(v) for v in ys)))
        else:
            coords = ", ".join("(%s, %s)" % (_n(h["x"]), _n(h["y"]))
                               for h in sorted(hs, key=lambda h: (-h["y"], h["x"])))
            out.append("%d hole%s %s mm diameter at %s mm from centre"
                       % (len(hs), "" if len(hs) == 1 else "s", _n(d), coords))
    return out


def group_slots(slots):
    out = []
    key = {}
    for s in slots:
        key.setdefault((round(s["length"], 1), round(s["width"], 1),
                        s["vertical"]), []).append(s)
    for (L, W, vert), ss in sorted(key.items()):
        axis = "vertically" if vert else "horizontally"
        coords = ", ".join("(%s, %s)" % (_n(s["x"]), _n(s["y"]))
                           for s in sorted(ss, key=lambda s: (-s["y"], s["x"])))
        out.append("%d slot%s %s mm long by %s mm wide with fully radiused ends, "
                   "running %s, centred at %s mm from centre"
                   % (len(ss), "" if len(ss) == 1 else "s", _n(L), _n(W), axis, coords))
    return out


def describe(path):
    doc = ezdxf.readfile(path)
    msp = doc.modelspace()
    cut_holes, cut_slots, cut_other, bends, etch = [], [], [], [], []
    profile = None
    best = 0
    for e in msp:
        c = classify(e)
        if not c:
            continue
        kind, d = c
        layer = d.get("layer", "CUT")
        if layer == "BEND":
            bends.append(d)
            continue
        if layer == "ETCH":
            etch.append((kind, d))
            continue
        if kind == "hole":
            cut_holes.append(d)
        elif kind == "slot":
            cut_slots.append(d)
        else:
            a = d.get("w", 0) * d.get("h", 0)
            if a > best:
                if profile:
                    cut_other.append(profile)
                best, profile = a, (kind, d)
            else:
                cut_other.append((kind, d))
    return dict(profile=profile, holes=cut_holes, slots=cut_slots,
                other=cut_other, bends=bends, etch=etch)


def profile_words(kind, d):
    if kind == "rrect":
        if abs(d["w"] - d["h"]) < TOL:
            return ("a %s mm square with %s mm radii on all four corners"
                    % (_n(d["w"]), _n(d["r"])))
        return ("a %s mm wide by %s mm tall rectangle with %s mm radii on all "
                "four corners" % (_n(d["w"]), _n(d["h"]), _n(d["r"])))
    if kind == "rect":
        return "a %s mm by %s mm rectangle with sharp corners" % (_n(d["w"]), _n(d["h"]))
    if kind == "cross":
        return ("a cross shaped blank: a %s mm square in the middle with a %s mm "
                "deep flange projecting from each of its four sides, and the four "
                "outside corners relieved by a small 1.6 mm notch so the folds do "
                "not tear. Overall %s mm across the flanges both ways"
                % (_n(d["base"]), _n(d["flange"]), _n(d["w"])))
    if kind == "notched":
        return ("a %s mm wide by %s mm tall rectangle with a notch cut out of "
                "each of the four corners. Each notch is %s mm deep, measured "
                "from the top or bottom edge, and runs from the end of the part "
                "inward to x = plus or minus %s mm. The middle band of the part, "
                "%s mm tall, runs the full %s mm width"
                % (_n(d["w"]), _n(d["h"]), _n(d["band"]), _n(d["run"] / 2),
                   _n(d["h"] - 2 * d["band"]), _n(d["w"])))
    if kind == "quarter":
        return ("a quarter circle of radius %s mm: two straight edges meeting at "
                "a right angle and a convex arc joining their far ends" % _n(d["r"]))
    return ("an irregular closed profile %s mm wide by %s mm tall with %d vertices"
            % (_n(d["w"]), _n(d["h"]), d["n"]))


def lines(path):
    f = describe(path)
    out = []
    if f["profile"]:
        kind, d = f["profile"]
        if kind == "cross" and f["bends"]:
            span = max(abs(b["y0"]) for b in f["bends"] if abs(b["y0"] - b["y1"]) < TOL)
            d = dict(d, base=2 * span, flange=(d["w"] - 2 * span) / 2)
        out.append("Outline: " + profile_words(kind, d) + ".")
    for kind, d in f["other"]:
        if kind in ("rect", "rrect"):
            out.append("Cut out %s, centred on the part."
                       % profile_words(kind, d).replace("a ", "an inner ", 1))
    out += ["Cut " + s + "." for s in group_holes(f["holes"])]
    out += ["Cut " + s + "." for s in group_slots(f["slots"])]
    if f["bends"]:
        hz = [b for b in f["bends"] if abs(b["y0"] - b["y1"]) < TOL]
        vt = [b for b in f["bends"] if abs(b["x0"] - b["x1"]) < TOL]
        parts = []
        if hz:
            parts.append("%d horizontal at y = %s mm"
                         % (len(hz), ", ".join(_n(b["y0"]) for b in
                                               sorted(hz, key=lambda b: -b["y0"]))))
        if vt:
            parts.append("%d vertical at x = %s mm"
                         % (len(vt), ", ".join(_n(b["x0"]) for b in
                                               sorted(vt, key=lambda b: b["x0"]))))
        out.append("Bend lines (do not cut): " + "; ".join(parts) + ".")
    squares = [d for k, d in f["etch"] if k in ("rect", "rrect")]
    tri = [d for k, d in f["etch"] if k == "outline"]
    if squares:
        out.append("Etch (do not cut): %d squares %s mm on a side, on a 160 mm "
                   "grid centred on the part. These mark where the LED panels sit."
                   % (len(squares), _n(squares[0]["w"])))
    if tri:
        out.append("Etch (do not cut): a small filled triangle near the top edge, "
                   "pointing down, as an orientation mark.")
    return out


def main():
    import sys
    src = sys.argv[1] if len(sys.argv) > 1 else "cad"
    for f in sorted(glob.glob(os.path.join(src, "*.dxf"))):
        print("\n== %s" % os.path.basename(f))
        for l in lines(f):
            print("   " + l)


if __name__ == "__main__":
    main()
