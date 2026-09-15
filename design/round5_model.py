"""Round five: three objects out of the eight that were kept.

The eight say less about style than they look. Read together they are four
rules. Symmetric and centred, because every asymmetric body was cut. Closed
and resolved from behind, because both fully enclosed bodies survived and
every open-backed one did not. One precise bright edge between the picture
and the body, which all eight have. And a silhouette that is not a plain
extruded box: Strap's 50 mm corners, Soft Monument's octagon, Splay's funnel.

To that the owner added a fifth rule by hand, redrawing Strap: a border
inside a rounded body should be a parallel curve of it, not a square frame
sitting in a round hole. Every radius here is `concentric()`: the same arc
struck from the same centre, its radius shrinking by exactly what the border
is wide.

What this round deliberately does not do is combine. Round four's two
syntheses were both cut and its one argument was kept, so each of these
takes a single idea from the eight and finishes it.

    offset   the geometry. A satin aluminium body with 50 mm corners and a
             stepped mount of four concentric rings rising to the picture,
             alternating anodised black and bare alloy. Index's honest depth,
             Case's precise edge, Strap's rule made the whole subject. Off it
             is a stepped aluminium square.
    cove     the light. Splay's argument that the surround should catch the
             record's own colour, with the four flat walls replaced by one
             continuous concave fillet, so there is no edge anywhere between
             the picture and the plaster. Bone, and 90 mm deep instead of 196.
    ply      the material. Wall VI box's carcass and price, with the corners
             and the aperture routed through 18 mm birch and the laminations
             left raw against a matte black face. The only ornament is what
             the cutter did.

Every verified number comes from wall_model.py and alt_model.py. New numbers
are marked the same way: VERIFIED / LISTING / TYPICAL / DESIGN.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python design/round5_model.py -- --design offset \
        --out design/renders --face design/face192.png
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy

import wall_model as W
import alt_model as A
from wall_model import mm, box, cylinder, material, collection, link
from alt_model import rounded_rect, slab

FACE = W.FACE                          # 480
AIR = A.AIR                            # 6.7      glass over the LEDs
ACR_T = W.ACR_T                        # 3.175    1/8 in
CAVITY = A.CAVITY                      # 63.5     supply, bars, fuses and Pi
BACK_T = W.BACK_T                      # 6.35     1/4 in ply
Z_STEEL_FRONT = A.Z_STEEL_FRONT        # -25.1
Z_STEEL_BACK = A.Z_STEEL_BACK
Z_PLY_BACK = A.Z_PLY_BACK              # -38.56

Z_CAV_BACK = Z_PLY_BACK - CAVITY       # -102.06  the back of the equipment bay
Z_BACK = Z_CAV_BACK - BACK_T           # -108.41  the outside of the back panel
WALL_PAD = 16.0                        # DESIGN   the boxed enclosure's number
VENT = (340.0, 22.0)                   # DESIGN   the atelier study's opening

# Round six. Each of these is one change to an object the owner already likes,
# named by him: Cove's border is too big, Ply's gold does not fit the room, and
# Section's bare aluminium does not either.
COVE_R = 90.0                          # the cove's section, and so its border
ACCENT = "brass"                       # Ply's one line
FRAME_MAT = "clear_anod"               # Section's extrusion


# ============================================================ the one rule

def concentric(outer, radius, width):
    """The same corner, offset inward. A border `width` across the object
    shrinks the radius by half the difference, which is what makes two curves
    read as one line instead of two frames."""
    return max(1.0, radius - (outer - width) / 2)


def ring_outline(outer, radius, width):
    return rounded_rect(width, width, concentric(outer, radius, width))


def swept(name, rings, col, mat, thickness=0.0, smooth=True):
    """A surface lofted through rings of the same point count.

    `rounded_rect` always returns four arcs of eleven points, and offsetting a
    rounded rectangle outward by d raises its radius by exactly d, so a cove
    swept between two of them is a true parallel surface and the quads write
    themselves.
    """
    verts, faces = [], []
    n = len(rings[0][0])
    for pts, z in rings:
        verts += [(mm(x), mm(y), mm(z)) for x, y in pts]
    for k in range(len(rings) - 1):
        a, c = k * n, (k + 1) * n
        for i in range(n):
            j = (i + 1) % n
            faces.append((a + i, a + j, c + j, c + i))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    o = bpy.data.objects.new(name, me)
    if mat:
        me.materials.append(mat)
    if thickness:
        s = o.modifiers.new("Solidify", "SOLIDIFY")
        s.thickness, s.offset = mm(thickness), 1.0
    if smooth:
        for p in me.polygons:
            p.use_smooth = True
    link(o, col)
    return o


def plate(b, name, outer, inner, t, z_back, mat, S, R, layer=1):
    """One ring of the stepped mount: a rounded slab with a rounded hole."""
    p = b.part(slab(name, rounded_rect(outer, outer, concentric(S, R, outer)),
                    t, z_back + t / 2, b.cols["Face"], mat), layer)
    b.cut_outline(p, f"{name} opening",
                  rounded_rect(inner, inner, concentric(S, R, inner)), t + 12, z_back + t / 2)
    return p


def ring(b, name, outer, inner, t, z_back, mat, S, R, layer=1):
    return plate(b, name, outer, inner, t, z_back, mat, S, R, layer)


def hollow(b, shell, cav, z_from, z_to):
    """The equipment bay, cut out of a solid body."""
    b.cut(shell, "Body cavity", (cav, cav, z_to - z_from + 4),
          (0, 0, (z_from + z_to) / 2 - 2))


def vents(b, panel, w, z):
    """Two guarded slots, low behind the supply's fan and high clear of the
    cleat. The number is the atelier study's."""
    CUT = bpy.data.collections.get("Cutters body") or collection("Cutters body")
    CUT.hide_render = True
    for i, dy in enumerate((-w / 2 + 74, w / 2 - 96)):
        v = b.part(box(f"Vent {i}", (min(VENT[0], w - 110), VENT[1], BACK_T + 8),
                       (0, dy, z), CUT), 5)
        m = panel.modifiers.new(f"Vent {i}", "BOOLEAN")
        m.operation, m.object, m.solver = "DIFFERENCE", v, "EXACT"


def pads(b, name_mat, span, z_back_face, pad=WALL_PAD):
    for i, (sx, sy) in enumerate(((-1, 1), (1, 1), (-1, -1), (1, -1))):
        b.part(box(f"Wall pad {i}", (34, 34, pad),
                   (sx * (span / 2 - 60), sy * (span / 2 - 60), z_back_face - pad / 2),
                   b.cols["Body"], name_mat), 7)
    return z_back_face - pad


def mark(b, cx, cy, z, mat_dark, mat_lit):
    """The app's seven by seven lattice, one tile lit. A stencil and a
    fingertip of paint on the buildable wall; brass here. It costs nothing and
    the object should carry the mark the app does."""
    pitch, sq = 3.0, 2.0
    for r in range(7):
        for c in range(7):
            m = mat_lit if (r, c) == (2, 4) else mat_dark
            b.part(box(f"Mark {r}{c}", (sq, sq, 0.6),
                       (cx - 9 + c * pitch, cy + 9 - r * pitch, z), b.cols["Face"], m), 1)


def mitred(b, name, outer, face, z_back, t, mat, layer=0):
    """Four rails of one extruded section, mitred at 45 degrees. The joint is
    the only line on the frame, which is the whole idea: a section, cut four
    times, is a cheaper and more honest frame than four machined corners."""
    o, i = outer / 2, outer / 2 - face
    for n, pts in enumerate((
            [(-o, o), (o, o), (i, i), (-i, i)],
            [(o, -o), (-o, -o), (-i, -i), (i, -i)],
            [(-o, -o), (-o, o), (-i, i), (-i, -i)],
            [(o, o), (o, -o), (i, -i), (i, i)])):
        b.part(slab(f"{name} {n}", pts, t, z_back + t / 2, b.cols["Body"], mat), layer)
    return outer - 2 * face


def square_bezel(b, name, opening, face, t, z, mat, layer=1):
    """The one dark line, with square corners."""
    ho = opening / 2 + face / 2
    for n, (dx, dy, sx, sy) in enumerate((
            (0, ho, opening + 2 * face, face), (0, -ho, opening + 2 * face, face),
            (-ho, 0, face, opening), (ho, 0, face, opening))):
        b.part(box(f"{name} {n}", (sx, sy, t), (dx, dy, z),
                   b.cols["Face"], mat, bevel=0.15), layer)


def stack(b, S, R, steel=540.0, glass=536.0):
    """The board, the steel the panels hold to, and the glass. Steel and glass
    are rounded to the same family as everything else: a square sheet behind a
    rounded aperture shows four dark corners, which is what the first cove
    render did."""
    b.part(box("Board", (S - 20, S - 20, W.PLY_T), (0, 0, Z_STEEL_BACK - W.PLY_T / 2),
               b.cols["Body"], b.m["black"], bevel=0.6), 5)
    b.part(slab("Steel skin", rounded_rect(steel, steel, concentric(S, R, steel)),
                W.STEEL_T, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2, b.cols["Body"], b.m["black"]), 5)
    b.part(slab("Smoked acrylic", rounded_rect(glass, glass, concentric(S, R, glass)),
                ACR_T, AIR + ACR_T / 2, b.cols["Face"], b.m["smoke"]), 1)


# ================================================================== the build

class RBuild(A.Build):
    """alt_model's Build, plus what these three are made of."""

    def __init__(self, face_png, lit, cloth_name, **kw):
        super().__init__(face_png, lit, cloth_name, **kw)
        # Flat brushed metal facing a dark studio mirrors the dark studio. The
        # alternates found this at 0.28 and settled on 0.42 with almost no
        # anisotropy: a diffuse sheen that still reads as machined.
        self.m["satin"] = W.brushed_material("Satin aluminium", (0.88, 0.885, 0.90), 0.50, 0.08)
        self.m["anodised"] = W.brushed_material("Black anodised", (0.042, 0.042, 0.045), 0.38, 0.25)
        # Bone, and paler than the alternates' bone: this one is a reflector,
        # and its whole job is to take the record's colour off the panels.
        self.m["chalk"] = A.board_material("Bone lacquer", (0.74, 0.725, 0.685), 0.62)
        self.m["oiled"] = A.board_material("Matte black, sprayed", (0.020, 0.020, 0.021), 0.72)
        # Birch plies: seven laminations, alternating a shade because that is
        # what a routed edge actually looks like.
        self.m["ply_pale"] = A.board_material("Birch lamination, pale", (0.60, 0.485, 0.315), 0.55)
        self.m["ply_warm"] = A.board_material("Birch lamination, warm", (0.47, 0.345, 0.195), 0.58)
        self.m["glue"] = A.board_material("Glue line", (0.22, 0.16, 0.10), 0.6)
        # The room: a white deck, two white speakers and a brushed lamp. These
        # two are those, and they are the reason Section belongs on that wall.
        self.m["clear_anod"] = W.brushed_material("Clear anodised aluminium",
                                                  (0.72, 0.725, 0.735), 0.34, 0.30)
        self.m["ivory"] = material("Off-white lacquer", (0.755, 0.740, 0.695), 0.38, coat=0.5)
        # gold does not fit the room; blackened steel is the same line without it
        self.m["blacksteel"] = W.brushed_material("Blackened steel", (0.075, 0.073, 0.076),
                                                  0.34, 0.35)
        self.m["black_anod"] = W.brushed_material("Black anodised aluminium",
                                                  (0.052, 0.052, 0.055), 0.36, 0.30)


# ==================================================================== offset

def offset(b):
    """Satin aluminium, 50 mm corners, and a stepped mount of four rings.

    Index argued that this should read as a piece of audio equipment and get
    there through seams and proportion rather than features, and it kept an
    honest side rather than pretending nine panels are a thin LCD. Case put
    one bright anodised edge 3 mm proud of the glass. Strap said the borders
    should be parallel curves. This is those three taken to the end: instead
    of one bright edge there are four, each a step of 6 mm, alternating bare
    alloy and anodised black, rising 12 mm from the body to the picture.

    Every arc is struck from the same centre 230 mm out on each axis, so the
    radius runs 50, 44, 38, 32 at the steps' outer edges and 36, 30, 24, 18 at
    their openings. Nothing on the object is a straight-to-corner join.
    """
    S, R = 560.0, 50.0
    # 9 mm of face per step and only 2 mm of rise: at 3 and 6 the first render
    # put every step in the shadow of the one in front and the alternation
    # stopped reading, which is the whole idea.
    STEP_T = 2.0
    z_glass_front = AIR + ACR_T        # 9.875
    z_body_front = z_glass_front
    depth = z_body_front - Z_CAV_BACK
    b.panels()
    body = b.part(slab("Body", rounded_rect(S, S, R), depth,
                       (z_body_front + Z_CAV_BACK) / 2, b.cols["Body"], b.m["satin"]), 5)
    hollow(b, body, S - 24, Z_CAV_BACK, Z_STEEL_FRONT + 1)
    b.cut_outline(body, "Body aperture", rounded_rect(516.0, 516.0, concentric(S, R, 516.0)),
                  z_body_front - Z_STEEL_FRONT + 10, (z_body_front + Z_STEEL_FRONT) / 2 + 3)
    # the carcass the panels actually sit on, inside that body
    stack(b, S, R)
    # the mount: four rings, out to in, alternating anodised and bare
    z = z_body_front
    for i, (outer, inner) in enumerate(((560.0, 542.0), (542.0, 524.0),
                                        (524.0, 506.0), (506.0, 496.0))):
        mat = b.m["satin"] if i % 2 == 0 else b.m["anodised"]
        plate(b, f"Step {i + 1}", outer, inner, STEP_T, z, mat, S, R)
        z += STEP_T
    z_front = z
    backp = b.part(slab("Back panel", rounded_rect(S, S, R), BACK_T,
                        Z_CAV_BACK - BACK_T / 2, b.cols["Body"], b.m["satin"]), 5)
    vents(b, backp, S, Z_CAV_BACK - BACK_T / 2)
    z_wall = pads(b, b.m["satin"], S, Z_BACK)
    b.halo(S - 60, S - 60, Z_BACK - 4.0, strength=30.0)
    # Index's inlet: underneath, 165 to the right, reached with the right hand
    b.mains((165.0, -S / 2 + 2.0, Z_PLY_BACK - CAVITY / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -165.0), bars=(-165.0, 130.0), fuse=(-35.0, 25.0),
                  pi=(175.0, 130.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=z_front, back=z_wall, height=1500.0,
                label="Offset", centre_y=0.0, pads=WALL_PAD, switch_down=True)


# ====================================================================== cove

def cove(b):
    """One continuous concave fillet from the picture back to the plaster.

    Splay's argument was the best thing in round two and the owner kept it:
    the surround should be pale, not black, so the artwork floods it with its
    own colour and the object blooms in whatever is playing, and the slope
    cuts the off-axis glare a flat smoked sheet cannot. Its cost was four flat
    trapezoids meeting at four hard corners, and 196 mm of depth.

    A cove is the same idea with the corners taken out. The section is a
    quarter circle of 90 mm swept around a rounded rectangle, and because
    offsetting a rounded rectangle outward by d raises its radius by exactly
    d, every ring of that sweep is a parallel curve of the one before it. The
    result has no edge anywhere between the picture and the wall: the object
    does not end, it fades.
    """
    THROAT, R_THROAT, COVE = 496.0, 40.0, COVE_R
    z_throat = 12.0
    STEPS = 14
    S = THROAT + 2 * COVE              # 676 at the wall
    R_OUT = R_THROAT + COVE            # 130
    b.panels()
    rings = []
    for i in range(STEPS + 1):
        t = math.radians(90.0 * i / STEPS)
        d = COVE * math.sin(t)
        rings.append((rounded_rect(THROAT + 2 * d, THROAT + 2 * d, R_THROAT + d),
                      z_throat - COVE * (1 - math.cos(t))))
    z_rim = rings[-1][1]               # -78
    b.part(swept("Cove", rings, b.cols["Body"], b.m["chalk"], thickness=6.0), 5)
    # the plinth: same outline, so the silhouette is unbroken, and it is what
    # the equipment actually lives in
    plinth = b.part(slab("Plinth", rounded_rect(S, S, R_OUT), z_rim - Z_CAV_BACK,
                         (z_rim + Z_CAV_BACK) / 2, b.cols["Body"], b.m["chalk"]), 5)
    hollow(b, plinth, S - 90, Z_CAV_BACK, z_rim + 4)
    stack(b, THROAT, R_THROAT, steel=524.0, glass=516.0)
    # Index's one dark line, at the throat, where the cove starts
    ring(b, "Throat reveal", 502.0, 488.0, 3.0, z_throat - 1.5, b.m["anodised"],
         THROAT + 12, R_THROAT + 6)
    backp = b.part(slab("Back panel", rounded_rect(S, S, R_OUT), BACK_T,
                        Z_CAV_BACK - BACK_T / 2, b.cols["Body"], b.m["chalk"]), 5)
    vents(b, backp, S, Z_CAV_BACK - BACK_T / 2)
    z_wall = pads(b, b.m["chalk"], S - 60, Z_BACK)
    b.halo(S - 120, S - 120, Z_BACK - 4.0, strength=26.0)
    # Splay's switch: under the bottom, facing the floor, found by feel
    b.mains((0.0, -S / 2 + 34.0, Z_PLY_BACK - CAVITY / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -175.0), bars=(-175.0, 130.0), fuse=(-35.0, 25.0),
                  pi=(180.0, 130.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=z_throat, back=z_wall, height=1500.0,
                label="Cove", centre_y=0.0, pads=WALL_PAD, switch_down=True)


# ======================================================================= ply

def ply(b):
    """Eighteen millimetres of birch, routed, and nothing else.

    Wall VI box is the object that is actually going to be built, and it is
    the only one of the eight that costs $150 rather than $250. This keeps its
    carcass, its price and its enclosure, and spends the difference on one
    detail: a 50 mm radius routed through 18 mm birch ply, and the same
    radius through the aperture. A cutter through birch exposes seven
    laminations as a fine striped arc, and that stripe is the only ornament on
    the object. The face is sprayed matte black and the routed edges are left
    raw and oiled, so the ornament is exactly the part the tool made.

    One brass line at the aperture, and the app's lattice in brass on the
    bottom border, and the same rear halo every other design has.
    """
    S, R = 580.0, 50.0
    # The aperture is routed as a bevel, not a straight wall. Cut square, the
    # laminations only show on the outer edge and from the front the object is
    # a black frame with a gold line, which is Strap. Flared 26 mm over the
    # sheet's 18, they are a striped bevel around the picture, seen head on,
    # and they are the only ornament the object has.
    BACK_OPEN, OPEN, PLY_T, LAM = 496.0, 522.0, 18.0, 7
    z_ply_back = AIR + ACR_T           # the sheet sits straight on the glass
    z_front = z_ply_back + PLY_T
    b.panels()
    body = b.part(slab("Body", rounded_rect(S, S, R), z_ply_back - Z_CAV_BACK,
                       (z_ply_back + Z_CAV_BACK) / 2, b.cols["Body"], b.m["oiled"]), 5)
    hollow(b, body, S - 24, Z_CAV_BACK, Z_STEEL_FRONT + 1)
    b.cut_outline(body, "Body aperture", rounded_rect(516.0, 516.0, concentric(S, R, 516.0)),
                  z_ply_back - Z_STEEL_FRONT + 10, (z_ply_back + Z_STEEL_FRONT) / 2 + 3)
    stack(b, S, R, steel=544.0, glass=538.0)
    # the sheet, one lamination at a time, each cut a little wider than the one
    # behind it, so the bevel is a stair of seven stripes
    t = PLY_T / LAM
    outline = rounded_rect(S, S, R)
    for i in range(LAM):
        mat = b.m["ply_pale"] if i % 2 == 0 else b.m["ply_warm"]
        w = BACK_OPEN + (OPEN - BACK_OPEN) * i / (LAM - 1)
        lam = b.part(slab(f"Lamination {i + 1}", outline, t, z_ply_back + t * (i + 0.5),
                          b.cols["Face"], mat), 1)
        b.cut_outline(lam, f"Lamination {i + 1} opening",
                      rounded_rect(w, w, concentric(S, R, w)), t + 8,
                      z_ply_back + t * (i + 0.5))
    paint = b.part(slab("Sprayed face", outline, 0.5, z_front + 0.25,
                        b.cols["Face"], b.m["oiled"]), 1)
    b.cut_outline(paint, "Sprayed face opening",
                  rounded_rect(OPEN, OPEN, concentric(S, R, OPEN)), 8.0, z_front + 0.25)
    # the one brass line, let into the face around the aperture
    # proud of the sprayed face rather than flush in it: a 1.2 mm ring lying
    # coplanar with the paint z-fights, and a line you can feel is the point
    ring(b, "Accent line", OPEN + 10.0, OPEN, 1.2, z_front + 0.5, b.m[ACCENT], S, R)
    mark(b, 0.0, -S / 2 + 15.0, z_front + 0.8, b.m["oiled"], b.m[ACCENT])
    backp = b.part(slab("Back panel", rounded_rect(S, S, R), BACK_T,
                        Z_CAV_BACK - BACK_T / 2, b.cols["Body"], b.m["oiled"]), 5)
    vents(b, backp, S, Z_CAV_BACK - BACK_T / 2)
    z_wall = pads(b, b.m["oiled"], S, Z_BACK)
    b.halo(S - 70, S - 70, Z_BACK - 4.0, strength=28.0)
    b.mains((165.0, -S / 2 + 2.0, Z_PLY_BACK - CAVITY / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -165.0), bars=(-165.0, 130.0), fuse=(-35.0, 25.0),
                  pi=(175.0, 130.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=z_front, back=z_wall, height=1500.0,
                label="Ply", centre_y=0.0, pads=WALL_PAD, switch_down=True)




# =================================================================== section

def section(b):
    """One extruded aluminium section, mitred four times, around a white plate.

    The other three in this round are round. This one has no radius anywhere,
    and it is drawn from the canon rather than from the eight: the objects that
    keep being collected and keep being copied.

    Braun's LE1 (Dieter Rams, 1959) is the direct parent. It is a flat panel in
    a slim anodised frame with a pale grille set into it, and the relationship
    between the frame and what it holds is the entire design. The Vitsoe 606
    system (Rams, 1960) is the second: the fixing is not hidden and not
    decorated, it is simply the smallest correct part. The SK4 (Rams and
    Gugelot, 1956) is the third, for the rule that a metal body and a plain
    face need no third idea. Fukasawa's wall-mounted player (1999) is the
    fourth, for one honest gesture and nothing else to press. And behind all
    of them is Rams' own tenth rule, that good design is as little design as
    possible. These are museum-collected designs rather than any one prize:
    MoMA holds the SK4, the V&A holds the player, and the 606 has been in
    production since 1960.

    What that gives, exactly. A 22 mm face of clear anodised aluminium in a
    120 mm deep section, mitred at each corner with a hairline joint and no
    fastener anywhere on the front. Set into it, 2 mm back, an off-white
    lacquered plate with a 487 mm square hole. Standing in that hole, a 1.5 mm
    black anodised bezel, and behind it the whole 480 mm picture, uncropped.
    No mark and no knob; the rear halo stays, because it is on every design now.

    Why it belongs on that wall. Every other body in this catalogue is black,
    walnut, bone or bare metal, and the room it is going into has a black cubby
    unit below and an off-white wall behind. A black object extends the
    furniture upward and a walnut one argues with it. This one is made of the
    two things already on top of that unit: the white deck and speakers, and
    the brushed aluminium of the lamp. It belongs to the equipment rather than
    to the furniture, which is what puts it on the wall instead of on the wall.
    """
    S, FRAME, MARGIN = 580.0, 22.0, 26.0       # 480 + 2 x (1.5 + 26 + 22)
    PLATE_T, PROUD = 6.0, 2.0
    OPEN, REVEAL = 487.0, 1.5
    z_plate_back = AIR + ACR_T                 # 9.875, straight on the glass
    z_plate_front = z_plate_back + PLATE_T
    z_front = z_plate_front + PROUD
    b.panels()
    b.part(box("Board", (S - 60, S - 60, W.PLY_T), (0, 0, Z_STEEL_BACK - W.PLY_T / 2),
               b.cols["Body"], b.m["black"], bevel=0.6), 5)
    b.part(box("Steel skin", (520.0, 520.0, W.STEEL_T),
               (0, 0, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2), b.cols["Body"], b.m["black"]), 5)
    b.part(box("Smoked acrylic", (514.0, 514.0, ACR_T), (0, 0, AIR + ACR_T / 2),
               b.cols["Face"], b.m["smoke"], bevel=0.4), 1)
    # the section: 22 of face, 120 of depth, four mitres, no radius
    inner = mitred(b, "Section", S, FRAME, Z_CAV_BACK, z_front - Z_CAV_BACK, b.m[FRAME_MAT])
    # the plate, set 2 mm inside the section
    plate_w = inner + 2.0                      # it sits in the section's rebate
    p = b.part(box("Lacquered plate", (plate_w, plate_w, PLATE_T),
                   (0, 0, z_plate_back + PLATE_T / 2), b.cols["Face"], b.m["ivory"],
                   bevel=0.3), 1)
    b.cut(p, "Plate opening", (OPEN, OPEN, PLATE_T + 12), (0, 0, z_plate_back + PLATE_T / 2))
    square_bezel(b, "Reveal", OPEN - 2 * REVEAL, REVEAL, PLATE_T + 1.0,
                 z_plate_back + PLATE_T / 2, b.m["anodised"])
    # the body inside the section, closed and vented
    bodyw = inner - 1.0
    body = b.part(box("Body", (bodyw, bodyw, z_plate_back - Z_CAV_BACK),
                      (0, 0, (z_plate_back + Z_CAV_BACK) / 2), b.cols["Body"],
                      b.m["black"]), 5)
    b.cut(body, "Body cavity", (bodyw - 24, bodyw - 24,
                                (Z_STEEL_FRONT + 1) - Z_CAV_BACK + 4),
          (0, 0, ((Z_STEEL_FRONT + 1) + Z_CAV_BACK) / 2 - 2))
    b.cut(body, "Body aperture", (520.0, 520.0, z_plate_back - Z_STEEL_FRONT + 10),
          (0, 0, (z_plate_back + Z_STEEL_FRONT) / 2 + 3))
    backp = b.part(box("Back panel", (S, S, BACK_T), (0, 0, Z_CAV_BACK - BACK_T / 2),
                       b.cols["Body"], b.m[FRAME_MAT], bevel=0.4), 5)
    vents(b, backp, S, Z_CAV_BACK - BACK_T / 2)
    z_wall = pads(b, b.m["black"], S, Z_BACK)
    b.halo(S - 70, S - 70, Z_BACK - 4.0, strength=28.0)
    b.mains((165.0, -S / 2 + 2.0, Z_PLY_BACK - CAVITY / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -165.0), bars=(-165.0, 130.0), fuse=(-35.0, 25.0),
                  pi=(175.0, 130.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=z_front, back=z_wall, height=1500.0,
                label="Section", centre_y=0.0, pads=WALL_PAD, switch_down=True)


DESIGNS = {"offset": offset, "cove": cove, "ply": ply,
           "section": section}


# ==================================================================== main

def main():
    global COVE_R, ACCENT, FRAME_MAT       # before argparse reads them as defaults
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="design/renders")
    ap.add_argument("--face", default="")
    ap.add_argument("--samples", type=int, default=160)
    ap.add_argument("--design", default="offset", choices=sorted(DESIGNS))
    ap.add_argument("--views", default="hero,front,side,corner,detail,off")
    ap.add_argument("--prefix", default="")
    ap.add_argument("--cove", type=float, default=COVE_R,
                    help="Cove's section in mm: 90 is the original, 32 is round six")
    ap.add_argument("--accent", default=ACCENT,
                    help="Ply's line: brass, blacksteel")
    ap.add_argument("--frame", default=FRAME_MAT,
                    help="Section's extrusion: clear_anod, black_anod")
    args = ap.parse_args(argv)
    COVE_R, ACCENT, FRAME_MAT = args.cove, args.accent, args.frame
    os.makedirs(args.out, exist_ok=True)
    prefix = args.prefix or args.design
    face = os.path.abspath(args.face) if args.face else ""
    views = args.views.split(",")

    def scene(lit=True):
        b = RBuild(face, lit, "charcoal")
        info = DESIGNS[args.design](b)
        b.place(info["back"], info["height"])
        b.studio()
        # An area light is camera-visible in Cycles by default, and the corner
        # camera looks back at the wall past the key, which put a grey wedge on
        # the plaster in the first detail render.
        for o in b.sc.objects:
            if o.type == "LIGHT":
                o.visible_camera = False
        b.inlet_world = (mm(b.inlet_at[0]), b.wall_y - mm(b.inlet_at[2]),
                         mm(info["height"]) + mm(b.inlet_at[1]))
        return b, info

    b, info = scene(True)
    W.glare(b.sc)
    C = (0.0, b.wall_y - mm(info["front"]) * 0.5, mm(info["height"]))
    span = max(info["w"], info["h"]) / 1000.0

    if "hero" in views:
        W.aim(b.cam, (-span * 1.5, -span * 2.3, C[2] + span * 0.28), C, lens=55, fstop=4.0)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-hero.png"), args.samples)
    if "front" in views:
        W.aim(b.cam, (0.0, -span * 3.1, C[2]), C, lens=60)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-front.png"), args.samples)
    if "side" in views:
        W.aim(b.cam, (span * 2.7, -span * 0.75, C[2] + 0.04), C, lens=50, fstop=11.0)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-side.png"), args.samples)
    if "corner" in views:
        k = (-mm(info["w"]) / 2 + 0.05, b.wall_y - mm(info["front"]),
             mm(info["height"]) + mm(info["h"]) / 2 - 0.05)
        W.aim(b.cam, (k[0] - 0.20, k[1] - 0.28, k[2] + 0.11), k, lens=85, fstop=5.6, focus=k)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-corner.png"), args.samples)
    if "detail" in views:
        t = b.inlet_world
        W.aim(b.cam, (t[0] + 0.16, t[1] - 0.40, t[2] - 0.26), t, lens=55, fstop=6.3, focus=t)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-detail.png"), args.samples)
    if "back" in views:
        b.lights["back"].hide_render = False
        W.aim(b.cam, (span * 1.1, span * 2.0, C[2] + span * 0.4),
              (0.0, b.wall_y * 0.4, C[2]), lens=42)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-back.png"), args.samples)
        b.lights["back"].hide_render = True
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(
        os.path.join(args.out, f"{prefix}.blend")))

    if "off" in views:
        b, info = scene(False)
        W.glare(b.sc)
        W.aim(b.cam, (-span * 1.5, -span * 2.3, C[2] + span * 0.28), C, lens=55, fstop=4.0)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-off.png"), args.samples)
    print(f"design {args.design}", flush=True)
    print(f"envelope {info['w']:.0f} x {info['h']:.0f} mm, "
          f"{info['front'] - info['back']:.1f} mm front to back", flush=True)


if __name__ == "__main__":
    main()
