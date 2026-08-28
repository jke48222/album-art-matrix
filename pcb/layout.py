#!/usr/bin/env python3
"""Generate backplane.kicad_pcb: real library footprints, placed + net-bound.

No KiCad needed to WRITE the board (it's S-expression text); KiCad is needed
later to fill zones, route, DRC and export gerbers.
"""
import copy
import importlib.util
import os
import re
import uuid as uuidlib

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle

HERE = os.path.dirname(os.path.abspath(__file__))

spec = importlib.util.spec_from_file_location("circuit", os.path.join(HERE, "circuit.py"))
circuit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(circuit)
PARTS, NETS = circuit.parts, circuit.nets

# ------------------------------------------------------------ s-expressions
class Sym(str):
    pass


TOK = re.compile(r'"(?:[^"\\]|\\.)*"|[()]|[^\s()"]+')


def parse(text):
    it = TOK.finditer(text)

    def build():
        out = []
        for m in it:
            t = m.group(0)
            if t == "(":
                out.append(build())
            elif t == ")":
                return out
            elif t.startswith('"'):
                out.append(t[1:-1].replace('\\"', '"').replace("\\\\", "\\"))
            else:
                out.append(Sym(t))
        return out

    for m in it:
        if m.group(0) == "(":
            return build()
    raise ValueError("no s-expression found")


def ser(n, ind=0):
    if isinstance(n, Sym):
        return str(n)
    if isinstance(n, str):
        return '"' + n.replace("\\", "\\\\").replace('"', '\\"') + '"'
    inner = [ser(c, ind + 1) for c in n]
    one = "(" + " ".join(inner) + ")"
    if len(one) <= 110 or ind > 6:
        return one
    pad = "\n" + "  " * (ind + 1)
    return "(" + inner[0] + pad + pad.join(inner[1:]) + "\n" + "  " * ind + ")"


def S(*args):
    out = []
    for a in args:
        out.append(Sym(str(a)) if isinstance(a, (int, float)) or isinstance(a, Sym) else a)
    return out


def sym(*args):
    return [Sym(str(a)) for a in args]


# ------------------------------------------------------------ net numbering
net_id = {name: i for i, name in enumerate(sorted(NETS), 1)}
pad_net = {}
for name, nodes in NETS.items():
    for ref, pin in nodes:
        pad_net[(ref, str(pin))] = (net_id[name], name)

# ------------------------------------------------------------ placement (mm)
YC = {1: 24, 2: 57, 3: 90}
PLACE = {"J_PI": (8, 12), "JP1": (66, 10), "PF1": (76, 12), "D1": (88, 10),
         "J_QT1": (114, 7), "J_QT2": (128, 7), "RP1": (138, 7), "RP2": (144, 7),
         "U1": (24, 34), "C1": (24, 42), "U2": (24, 60), "C2": (24, 68),
         "U3": (24, 86), "C3": (24, 94), "U4": (38, 44), "C4": (38, 52),
         "RN1": (58, 30), "RN2": (58, 38), "RN3": (58, 56), "RN4": (58, 64),
         "RN5": (58, 82), "RN6": (58, 90), "RN7": (52, 44),
         "J_HUB1": (76, 26), "J_HUB2": (76, 57), "J_HUB3": (76, 88),
         "JP_E1": (90, 34), "JP_E2": (90, 65), "JP_E3": (90, 96)}
for s in (1, 2, 3):
    yc = YC[s]
    PLACE[f"TB{s}"] = (158, yc - 8)
    PLACE[f"CB{s}1"] = (138, yc - 8)
    PLACE[f"CB{s}2"] = (148, yc + 4)
    for k in (1, 2, 3, 4):
        PLACE[f"CM{s}{k}"] = (128 + 7 * k, yc + 12)
    PLACE[f"RL{s}"] = (158, yc + 3)
    PLACE[f"LED{s}"] = (164, yc + 3)
    for k in (1, 2, 3):
        i = (s - 1) * 3 + k
        PLACE[f"F{i}"] = (112, yc - 11 + 11 * (k - 1))
        PLACE[f"J_PNL{i}"] = (97, yc - 11 + 11 * (k - 1))
HOLES = [(5, 5), (165, 5), (5, 105), (165, 105)]

# ------------------------------------------------------------ footprints
def fp_path(fpname):
    lib, name = fpname.split(":")
    return os.path.join(HERE, "footprints", f"{lib}.pretty_{name}.kicad_mod")


FP_CACHE = {}


def instantiate(ref, meta, x, y):
    fpname = meta["footprint"]
    if fpname not in FP_CACHE:
        FP_CACHE[fpname] = parse(open(fp_path(fpname)).read())
    node = copy.deepcopy(FP_CACHE[fpname])
    assert node[0] == "footprint" or str(node[0]) == "footprint"
    node[1] = fpname
    keep, pads_abs = [node[0], node[1]], []
    keep.append(S(Sym("uuid"), str(uuidlib.uuid4())))
    keep.append(sym("at", x, y))
    for child in node[2:]:
        if not isinstance(child, list):
            continue
        head = str(child[0]) if child else ""
        if head in ("version", "generator", "generator_version"):
            continue
        if head == "property" and len(child) > 2 and child[1] == "Reference":
            child[2] = ref
        elif head == "property" and len(child) > 2 and child[1] == "Value":
            child[2] = meta["value"]
        elif head == "fp_text" and len(child) > 2 and str(child[1]) == "reference":
            child[2] = ref
        elif head == "fp_text" and len(child) > 2 and str(child[1]) == "value":
            child[2] = meta["value"]
        elif head == "pad":
            num = str(child[1])
            hit = pad_net.get((ref, num))
            if hit:
                child.append(S(Sym("net"), Sym(hit[0]), hit[1]))
                if hit[1] == "GND":
                    child.append(sym("zone_connect", 2))
            for sub in child:
                if isinstance(sub, list) and sub and str(sub[0]) == "at":
                    pads_abs.append((x + float(sub[1]), y + float(sub[2]), num, ref,
                                     hit[1] if hit else ""))
                    break
        keep.append(child)
    return keep, pads_abs


# ------------------------------------------------------------ board
board = sym("kicad_pcb")
board.append(S(Sym("version"), Sym("20240108")))
board.append(S(Sym("generator"), "layoutpy"))
board.append(S(Sym("general"), sym("thickness", 1.6)))
board.append(S(Sym("paper"), "A3"))
L = [(0, "F.Cu", "signal"), (31, "B.Cu", "signal"),
     (32, "B.Adhes", "user", "B.Adhesive"), (33, "F.Adhes", "user", "F.Adhesive"),
     (34, "B.Paste", "user"), (35, "F.Paste", "user"),
     (36, "B.SilkS", "user", "B.Silkscreen"), (37, "F.SilkS", "user", "F.Silkscreen"),
     (38, "B.Mask", "user"), (39, "F.Mask", "user"),
     (40, "Dwgs.User", "user", "User.Drawings"), (41, "Cmts.User", "user", "User.Comments"),
     (44, "Edge.Cuts", "user"), (45, "Margin", "user"),
     (46, "B.CrtYd", "user", "B.Courtyard"), (47, "F.CrtYd", "user", "F.Courtyard"),
     (48, "B.Fab", "user"), (49, "F.Fab", "user")]
layers = sym("layers")
for row in L:
    ent = [Sym(str(row[0])), row[1], Sym(row[2])]
    if len(row) > 3:
        ent.append(row[3])
    layers.append(ent)
board.append(layers)
board.append(S(Sym("setup"), sym("pad_to_mask_clearance", 0)))
board.append(S(Sym("net"), Sym(0), ""))
for name, i in sorted(net_id.items(), key=lambda kv: kv[1]):
    board.append(S(Sym("net"), Sym(i), name))

all_pads = []
for ref, meta in sorted(PARTS.items()):
    x, y = PLACE[ref]
    node, pads = instantiate(ref, meta, x, y)
    board.append(node)
    all_pads.extend(pads)
for i, (hx, hy) in enumerate(HOLES, 1):
    node, _ = instantiate(f"H{i}", {"footprint": "MountingHole:MountingHole_3.2mm_M3",
                                    "value": "M3"}, hx, hy)
    PARTS.setdefault(f"H{i}", {"value": "M3"})
    board.append(node)


def bare_via(x, y, netname, size=0.6, drill=0.3):
    board.append([Sym("via"), sym("at", x, y), sym("size", size),
                  sym("drill", drill), S(Sym("layers"), "F.Cu", "B.Cu"),
                  sym("net", net_id[netname]),
                  S(Sym("uuid"), str(uuidlib.uuid4()))])

def bare_seg(x1, y1, x2, y2, w, netname, layer="F.Cu"):
    board.append([Sym("segment"), sym("start", x1, y1), sym("end", x2, y2),
                  sym("width", w), S(Sym("layer"), layer),
                  sym("net", net_id[netname]),
                  S(Sym("uuid"), str(uuidlib.uuid4()))])

# GND stitching: via-in-pad for SMD GND pads inside the VP bands
for x, y, num, ref, netname in all_pads:
    if netname == "GND" and (ref.startswith("CM") or ref.startswith("LED")):
        bare_via(x, y, "GND")
# buffer /OE + spare-input grounds: escape via beside pad19, column links 8-9-10
for ref in ("U1", "U2", "U3", "U4"):
    ux, uy = PLACE[ref]
    p19 = (ux + 2.8625, uy - 2.275)
    bare_seg(p19[0], p19[1], p19[0] + 1.4, p19[1], 0.25, "GND")
    bare_via(p19[0] + 1.4, p19[1], "GND")
for ref in ("U1", "U2", "U3"):
    ux, uy = PLACE[ref]
    x8 = ux - 2.8625
    bare_seg(x8, uy + 1.625, x8, uy + 2.275, 0.25, "GND")
    bare_seg(x8, uy + 2.275, x8, uy + 2.925, 0.25, "GND")

board.append([Sym("gr_rect"), sym("start", 0, 0), sym("end", 170, 110),
              S(Sym("stroke"), sym("width", 0.15), sym("type", "default")),
              S(Sym("layer"), "Edge.Cuts"),
              S(Sym("uuid"), str(uuidlib.uuid4()))])
board.append([Sym("gr_text"), "album-art-matrix backplane rev A",
              sym("at", 40, 105), S(Sym("layer"), "F.SilkS"),
              S(Sym("uuid"), str(uuidlib.uuid4())),
              [Sym("effects"), [Sym("font"), sym("size", 2.5, 2.5), sym("thickness", 0.4)]]])


def zone(netname, layer, rect, priority=0, solid=False):
    (x1, y1), (x2, y2) = rect
    z = sym("zone")
    z.append(S(Sym("net"), Sym(net_id[netname])))
    z.append(S(Sym("net_name"), netname))
    z.append(S(Sym("layer"), layer))
    z.append(S(Sym("uuid"), str(uuidlib.uuid4())))
    if priority:
        z.append(sym("priority", priority))
    z.append(S(Sym("hatch"), Sym("edge"), Sym(0.5)))
    if solid:
        z.append([Sym("connect_pads"), Sym("yes"), sym("clearance", 0.4)])
    else:
        z.append(S(Sym("connect_pads"), sym("clearance", 0.4)))
    z.append(sym("min_thickness", 0.3))
    z.append(S(Sym("fill"), Sym("yes"), sym("thermal_gap", 0.5),
               sym("thermal_bridge_width", 0.8),
               sym("island_removal_mode", 0)))
    pts = sym("pts")
    for px, py in ((x1, y1), (x2, y1), (x2, y2), (x1, y2)):
        pts.append(sym("xy", px, py))
    z.append([Sym("polygon"), pts])
    return z


for s in (1, 2, 3):
    board.append(zone(f"VP{s}", "F.Cu", ((93, YC[s] - 16), (168, YC[s] + 16)), priority=2, solid=True))
board.append(zone("GND", "F.Cu", ((0, 0), (170, 110))))
board.append(zone("GND", "B.Cu", ((0, 0), (170, 110))))

out = os.path.join(HERE, "backplane.kicad_pcb")
with open(out, "w") as fh:
    fh.write(ser(board) + "\n")
with open(os.path.join(HERE, "backplane.kicad_pro"), "w") as fh:
    fh.write('{"meta":{"filename":"backplane.kicad_pro","version":1}}\n')

reparsed = parse(open(out).read())
n_fp = sum(1 for c in reparsed if isinstance(c, list) and c and str(c[0]) == "footprint")
n_bound = sum(1 for p in all_pads if p[4])
print(f"board: {n_fp} footprints, {len(all_pads)} pads placed, {n_bound} pads net-bound")

# ------------------------------------------------------------ preview
fig, ax = plt.subplots(figsize=(12, 8))
ax.add_patch(Rectangle((0, 0), 170, 110, fill=False, ec="black", lw=2))
for s in (1, 2, 3):
    ax.add_patch(Rectangle((93, YC[s] - 16), 75, 32, fc="red", alpha=0.06, ec="red", ls="--", lw=0.7))
colors = {"GND": "#999999"}
for x, y, num, ref, net in all_pads:
    c = ("#cc3333" if net.startswith("VP") or net.startswith("VF") or net == "V5_PI"
         else "#999999" if net == "GND" else "#3366cc" if net else "#dddddd")
    ax.plot(x, y, "s", ms=2.2, color=c)
for ref in list(PLACE) + [f"H{i}" for i in (1, 2, 3, 4)]:
    x, y = (PLACE.get(ref) or dict(zip(["H1", "H2", "H3", "H4"], HOLES))[ref])
    ax.annotate(ref, (x, y), fontsize=5, ha="left", va="bottom", color="black")
ax.set_xlim(-6, 176); ax.set_ylim(116, -6)
ax.set_aspect("equal"); ax.grid(alpha=0.15)
ax.set_title("backplane rev A — auto-placement (red=5V pads/zones, gray=GND, blue=signal)")
fig.tight_layout()
fig.savefig(os.path.join(HERE, "placement.png"), dpi=115)
print("wrote placement.png")
