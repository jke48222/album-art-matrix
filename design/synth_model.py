"""Three more objects: two syntheses and one argument.

Alcove and Fascia are deliberate combinations of the six bodies that survived
review: ChatGPT's Index and Soft Monument, my Console and Vitrine, the boxed
enclosure, and the first walnut frame. Each takes the same six ideas and puts
its weight in a different place.

    alcove   walnut, and the picture at the bottom of a splayed wool well.
             Vitrine's recess given Index's bright edge and the walnut frame's
             body, chamfered the way Soft Monument chamfers, closed and vented
             the way the boxed enclosure is. The deep one.
    fascia   one sheet of glass over everything. A wool field with the picture
             let into it behind a narrow graphite reveal, a satin alloy case,
             walnut cheeks after the Braun SK4, and Console's instrument band
             turned into the rail you reach under. The flat one.

    shutter  not a synthesis. A walnut case with four shoji leaves that fold
             across the picture. Closed, the album is light on paper and the
             object is a lantern; folded back, it is the picture. The lineage
             is the winged altarpiece, whose wings were shut on ordinary days
             and opened on feasts, and Fukasawa's rule that a thing on a wall
             should ask for one honest gesture. Opening it is the switch.

Verified numbers come from wall_model.py and alt_model.py. What is new is
marked the same way: VERIFIED / LISTING / TYPICAL / DESIGN.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python design/synth_model.py -- --design alcove \
        --out design/renders --face design/face192.png
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
from mathutils import Vector

import wall_model as W
import alt_model as A
from wall_model import mm, box, cylinder, material, collection, link, cable

FACE = W.FACE                  # 480: three panels of 160
INLET = W.INLET                # LISTING  Antrader C14 with switch and fuse
AIR = A.AIR                    # 6.7      glass over the LEDs
ACR_T = W.ACR_T                # 3.175    1/8 in
CAVITY = A.CAVITY              # 63.5     what the supply, bars and Pi need
BACK_T = W.BACK_T              # 6.35     1/4 in ply
SEAM = W.PANEL                 # 160      the panel pitch: every seam is on it

Z_STEEL_FRONT = A.Z_STEEL_FRONT        # -25.1
Z_PLY_BACK = A.Z_PLY_BACK              # -38.56

# ---- the knob, and why it can exist ----------------------------------------
# The Triple Bonnet uses every header GPIO except pins 27 and 28 (ID_SD/ID_SC,
# GPIO0/1), which are I2C0, and docs/ASSEMBLY.md already puts the VEML7700
# there. A knob on plain GPIO is therefore impossible. An I2C knob is not:
# Adafruit 5880 is the seesaw rotary encoder breakout with the encoder fitted,
# default address 0x36, and the lux sensor is 0x10. Two devices, one bus, two
# pins, no second firmware and no cost to the spare panel. That is the whole
# reason Console's control comes back and Console's readout does not.
KNOB_D = 32.0                  # DESIGN    what a hand turns without looking
KNOB_H = 15.0                  # DESIGN    how far it stands off the band
ENCODER = (25.6, 25.3, 4.6)    # LISTING   Adafruit 5880 breakout, $7.95
BAND_H = 34.0                  # DESIGN    Console's band, 6 mm thinner
BAND_T = 3.0                   # LISTING   1/8 in alloy flat bar

# ---- the splayed well ------------------------------------------------------
# Vitrine put the picture 40 mm down a straight-sided cloth well and the cost
# was the viewing angle: at any angle off axis the near wall shadows a strip
# d*tan(theta) wide off the far side of the picture. Splaying the walls by
# 11.3 degrees opens the mouth from 484 to 500 and gives back that much before
# anything is clipped. It is also Soft Monument's chamfer, turned inward.
WALL_PAD = 30.0                # DESIGN    what holds the plinth off the wall so
                               #           the halo has something to wash. The
                               #           boxed enclosure used 16, which was
                               #           chosen for a box with no halo at all
WELL_D = 40.0                  # DESIGN    Vitrine's depth, unchanged
BEZEL_OPEN = FACE + 4          # 484: the alloy shows 2 mm past the LEDs
BEZEL_FACE = 6.0               # DESIGN    wide enough to cover the sheet's edge
WELL_IN = BEZEL_OPEN + 2 * BEZEL_FACE      # 496: the throat, at the glass
WELL_OUT = WELL_IN + 2 * WELL_D * 0.2      # 512: the mouth. 11.3 degrees
GLASS = BEZEL_OPEN + 8         # 492: small enough that the bezel laps its edge.
                               # At 508 the exposed 6 mm margin of acrylic was
                               # visible inside the well at a grazing angle and
                               # showed a stack of total-internal-reflection
                               # ghosts of the LED grid, which read as a louvre

# ---- the shoji leaves ------------------------------------------------------
# Kumiko on an 80 mm grid, exactly half the panel pitch, so every second bar
# lands on a seam. Laminated washi (Warlon and its kind) is the paper: washi
# faced both sides in resin, sold as the durable shoji paper, cleanable and
# flame-rated in Japan. Traditional shoji puts the lattice toward the room and
# the paper behind it, which is what is modelled.
KUMIKO = 80.0                  # DESIGN    half the 160 panel pitch
KUMIKO_W = 6.0                 # TYPICAL   a shoji lattice bar, face width. At 9
KUMIKO_D = 7.0                 #           by 12 the bars stood proud enough to
                               #           throw their own shadows and the leaf
                               #           read as a window grille with the wood
                               #           winning. Real kumiko is slender
STILE_W = 18.0                 # TYPICAL   a leaf's own frame. Four leaves means
                               #           a doubled stile at each joint, which
                               #           is what a folding screen actually is
LEAF_T = 22.0                  # DESIGN    stile depth: 18 face by 22
PAPER_T = 0.5                  # LISTING   Warlon laminated sheet, about 2 ml

# One more colourway than alt_model carries. Fascia needs a field pale enough
# to still read as wool with a 480 mm panel at full white beside it, and none
# of charcoal, oatmeal, oxblood, forest or ink is: through any glazing they all
# go to black next to the picture. Chalk does not.
A.CLOTH.setdefault("chalk", (0.560, 0.535, 0.480))


# ================================================================= materials

def lining_material(cloth_name, base):
    """The same wool, stretched over a return instead of laid on a flat panel.

    alt_model's cloth is two crossed wave bands at 260, and face on that is
    right: at 3.85 mm the weave is sub-pixel and averages into texture. On the
    well's splayed walls the same bands are foreshortened into a few pixels and
    alias into nine soft vertical flutes, which look like a machined feature
    that is not in the design. Zeroing the bump did not fix it, because the
    bands drive the colour ramp as well as the relief. A stretched lining gets
    a flat tone with fine noise instead: no bands to alias, and at two metres
    the wool still reads as wool.
    """
    m, nt, b = W.principled("Lining " + cloth_name)
    b.inputs["Base Color"].default_value = (*[c * 0.94 for c in base], 1.0)
    b.inputs["Roughness"].default_value = 0.95
    if "Sheen Weight" in b.inputs:
        b.inputs["Sheen Weight"].default_value = 0.35
        b.inputs["Sheen Roughness"].default_value = 0.40
    b.inputs["Specular IOR Level"].default_value = 0.16
    tex = nt.nodes.new("ShaderNodeTexCoord")
    n = nt.nodes.new("ShaderNodeTexNoise")
    n.inputs["Scale"].default_value = 1400.0
    n.inputs["Detail"].default_value = 2.0
    nt.links.new(tex.outputs["Object"], n.inputs["Vector"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.06
    nt.links.new(n.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m


def walnut_material():
    """Black walnut, oiled. Lifted from wall_model_walnut.py unchanged, because
    it was tuned once and it works: stretched noise rather than bands, because
    real grain is streaks of three or four tones that wander and a wave texture
    reads as fluting. Low specular, because dark wood under a softbox goes
    milky otherwise."""
    m = bpy.data.materials.get("Black walnut")
    if m:
        return m
    m, nt, bsdf = W.principled("Black walnut")
    bsdf.inputs["Roughness"].default_value = 0.52
    for name, val in (("Specular IOR Level", 0.28), ("Coat Weight", 0.0)):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = val
    tex = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (0.7, 26.0, 5.0)
    nt.links.new(tex.outputs["Object"], mapping.inputs["Vector"])
    grain = nt.nodes.new("ShaderNodeTexNoise")
    grain.inputs["Scale"].default_value = 2.6
    grain.inputs["Detail"].default_value = 9.0
    grain.inputs["Roughness"].default_value = 0.62
    nt.links.new(mapping.outputs[0], grain.inputs["Vector"])
    fine = nt.nodes.new("ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = 90.0
    fine.inputs["Detail"].default_value = 3.0
    nt.links.new(mapping.outputs[0], fine.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].position = 0.32
    cr.elements[0].color = (0.016, 0.009, 0.006, 1)
    cr.elements[1].position = 0.70
    cr.elements[1].color = (0.068, 0.036, 0.020, 1)
    mid = cr.elements.new(0.50)
    mid.color = (0.038, 0.020, 0.012, 1)
    nt.links.new(grain.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.025
    nt.links.new(fine.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def paper_material():
    """Laminated washi. A Principled BSDF cannot do this: transmission at high
    roughness is a rough refraction, not a scatter, and the picture would come
    through as a smeared image rather than as light. Translucent mixed with
    diffuse is the paper shader, and it does the one thing this design needs,
    which is that what arrives at the front is the artwork's colour and not
    the artwork."""
    m = bpy.data.materials.get("Washi")
    if m:
        return m
    m = bpy.data.materials.new("Washi")
    if hasattr(m, "use_nodes"):
        m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        if n.type != "OUTPUT_MATERIAL":
            nt.nodes.remove(n)
    out = nt.nodes[0]
    warm = (0.90, 0.855, 0.755, 1.0)
    diff = nt.nodes.new("ShaderNodeBsdfDiffuse")
    diff.inputs["Roughness"].default_value = 1.0
    trans = nt.nodes.new("ShaderNodeBsdfTranslucent")
    mix = nt.nodes.new("ShaderNodeMixShader")
    mix.inputs["Fac"].default_value = 0.66          # mostly translucent
    # fibres: long stretched noise, very low contrast. Real washi shows the
    # mulberry fibre as lighter streaks when it is lit from behind.
    tex = nt.nodes.new("ShaderNodeTexCoord")
    mp = nt.nodes.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (3.0, 190.0, 3.0)
    nt.links.new(tex.outputs["Object"], mp.inputs["Vector"])
    fib = nt.nodes.new("ShaderNodeTexNoise")
    fib.inputs["Scale"].default_value = 240.0
    fib.inputs["Detail"].default_value = 4.0
    nt.links.new(mp.outputs[0], fib.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.38
    ramp.color_ramp.elements[0].color = (0.80, 0.755, 0.660, 1)
    ramp.color_ramp.elements[1].position = 0.66
    ramp.color_ramp.elements[1].color = warm
    nt.links.new(fib.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], diff.inputs["Color"])
    nt.links.new(ramp.outputs["Color"], trans.inputs["Color"])
    nt.links.new(diff.outputs[0], mix.inputs[1])
    nt.links.new(trans.outputs[0], mix.inputs[2])
    nt.links.new(mix.outputs[0], out.inputs["Surface"])
    return m


# =================================================================== helpers

def rail(name, length, width, depth, at, rot_z, col, mat, taper=0.0):
    """A mitred rail: the inner edge is shorter by the width at each end, so
    four of them close a frame with no end grain showing. `taper` pulls the
    outer face in toward the back, which makes the body read thinner than it
    is and is one pass on a table saw. Both come from wall_model_walnut.py."""
    o = box(name, (length, width, depth), at, col, mat, bevel=0.8)
    half_l, w, t = mm(length) / 2, mm(width), mm(taper)
    for v in o.data.vertices:
        if v.co.y < 0:
            v.co.x = math.copysign(half_l - w, v.co.x)
        elif v.co.z < 0 and taper:
            # The taper pulls the outer face in, so the mitre plane has to
            # follow it in length as well. Moving only y left each rail's
            # outer back corner standing past its neighbour's, which rendered
            # as a small wing at all four corners.
            v.co.y -= t
            v.co.x = math.copysign(half_l - t, v.co.x)
    o.rotation_euler = (0, 0, rot_z)
    return o


def frame(b, name, outer_w, outer_h, face_w, z_front, z_back, cx, cy, mat,
          taper=6.0, layer=0):
    """Four mitred rails around an opening. Returns the inner opening."""
    zc, d = (z_front + z_back) / 2, z_front - z_back
    ox, oy = outer_w / 2 - face_w / 2, outer_h / 2 - face_w / 2
    for nm, at, rot, ln in (
            (f"{name} top", (cx, cy + oy, zc), 0.0, outer_w),
            (f"{name} bottom", (cx, cy - oy, zc), math.pi, outer_w),
            (f"{name} left", (cx - ox, cy, zc), math.pi / 2, outer_h),
            (f"{name} right", (cx + ox, cy, zc), -math.pi / 2, outer_h)):
        b.part(rail(nm, ln, face_w, d, at, rot, b.cols["Body"], mat, taper=taper), layer)
    return outer_w - 2 * face_w, outer_h - 2 * face_w


def body(b, board_w, board_h, cav_w, cav_h, cy, mat, depth=CAVITY, pad=WALL_PAD,
         halo_strength=32.0, steel=520.0):
    """The board, the steel skin, and a smaller closed plinth behind it.

    alt_model's carcass ran its rails at the board's own outline, so from any
    oblique angle the black box stood past the frame's edge and the object
    stopped resolving. Here the plinth is deliberately narrower than the face,
    which is the shadow gap the questionnaire asked for and hides the whole
    body from anywhere but straight on top of the object.

    Closed and vented, after the boxed enclosure: two 340 x 22 slots, low
    behind the supply's fan and high clear of the cleat, and four pads holding
    it off the wall. The pads are not decoration. The halo sits on the outer
    face of the back panel and needs a gap to wash, which the first version of
    the alternates found out by sealing it inside and lighting nothing.
    """
    CUT = bpy.data.collections.get("Cutters body") or collection("Cutters body")
    CUT.hide_render = True
    fur = W.FURRING
    b.part(box("Board", (board_w, board_h, W.PLY_T), (0, cy, A.Z_STEEL_BACK - W.PLY_T / 2),
               b.cols["Body"], mat, bevel=0.6), 5)
    b.part(box("Steel skin", (steel, steel, W.STEEL_T),
               (0, 0, (Z_STEEL_FRONT + A.Z_STEEL_BACK) / 2), b.cols["Body"], mat), 5)
    z_frame_back = Z_PLY_BACK - depth
    z_mid = Z_PLY_BACK - depth / 2
    for i, (dx, dy, sx, sy) in enumerate((
            (0, cav_h / 2 - fur / 2, cav_w, fur), (0, -cav_h / 2 + fur / 2, cav_w, fur),
            (-cav_w / 2 + fur / 2, 0, fur, cav_h - 2 * fur),
            (cav_w / 2 - fur / 2, 0, fur, cav_h - 2 * fur))):
        b.part(box(f"Cavity rail {i}", (sx, sy, depth), (dx, cy + dy, z_mid),
                   b.cols["Body"], mat), 5)
    backp = b.part(box("Back panel", (cav_w, cav_h, BACK_T), (0, cy, z_frame_back - BACK_T / 2),
                       b.cols["Body"], mat, bevel=0.5), 5)
    for i, vy in enumerate((-cav_h / 2 + 70, cav_h / 2 - 90)):
        v = b.part(box(f"Vent {i}", (min(340.0, cav_w - 90), 22.0, BACK_T + 8),
                       (0, cy + vy, z_frame_back - BACK_T / 2), CUT), 5)
        m = backp.modifiers.new(f"Vent {i}", "BOOLEAN")
        m.operation, m.object, m.solver = "DIFFERENCE", v, "EXACT"
    z_back_face = z_frame_back - BACK_T
    for i, (sx, sy) in enumerate(((-1, 1), (1, 1), (-1, -1), (1, -1))):
        b.part(box(f"Wall pad {i}", (34, 34, pad),
                   (sx * (cav_w / 2 - 46), cy + sy * (cav_h / 2 - 46),
                    z_back_face - pad / 2), b.cols["Body"], mat), 7)
    b.halo(cav_w, cav_h, z_back_face - 4.0, strength=halo_strength, cy=cy)
    return z_back_face - pad


def holed_plate(b, name, w, h, t, z_back, opening, cx, cy, ax, ay, mat, layer=1):
    """A sheet with a square hole cut where the picture goes."""
    CUT = bpy.data.collections.get("Cutters synth") or collection("Cutters synth")
    CUT.hide_render = True
    zc = z_back + t / 2
    p = b.part(box(name, (w, h, t), (cx, cy, zc), b.cols["Face"], mat, bevel=0.5), layer)
    c = b.part(box(f"{name} opening", (opening, opening, t + 10), (ax, ay, zc), CUT), layer)
    m = p.modifiers.new("Opening", "BOOLEAN")
    m.operation, m.object, m.solver = "DIFFERENCE", c, "EXACT"
    return p


def well(b, name, mouth, throat, z_mouth, z_throat, mat, cx=0.0, cy=0.0,
         thickness=6.0, layer=1):
    """Four trapezoids from a square mouth back to a smaller square throat.
    Straight-sided if mouth equals throat."""
    o, i = mouth / 2, throat / 2
    for n, corners in enumerate((
            ((-o, o, z_mouth), (o, o, z_mouth), (i, i, z_throat), (-i, i, z_throat)),
            ((o, -o, z_mouth), (-o, -o, z_mouth), (-i, -i, z_throat), (i, -i, z_throat)),
            ((-o, -o, z_mouth), (-o, o, z_mouth), (-i, i, z_throat), (-i, -i, z_throat)),
            ((o, o, z_mouth), (o, -o, z_mouth), (i, -i, z_throat), (i, i, z_throat)))):
        v = [(x + cx, y + cy, z) for (x, y, z) in corners]
        b.part(A.poly(f"{name} {n}", v, b.cols["Face"], mat, thickness), layer)


def bezel(b, name, opening, z, t, mat, cx=0.0, cy=0.0, face=3.0, layer=1):
    """The one bright millimetre. A length of alloy angle standing in the
    opening: Index's edge trim, Console's bezel and the walnut frame's black
    reveal are all this part, and it is the cheapest thing on the object."""
    ho = opening / 2 + face / 2
    for n, (dx, dy, sx, sy) in enumerate((
            (0, ho, opening + 2 * face, face), (0, -ho, opening + 2 * face, face),
            (-ho, 0, face, opening), (ho, 0, face, opening))):
        b.part(box(f"{name} {n}", (sx, sy, t), (cx + dx, cy + dy, z),
                   b.cols["Face"], mat, bevel=0.3), layer)


def band(b, w, cy, z_face, knob_x, mat_alloy, mat_dark, layer=1):
    """Console's instrument band: a strip of alloy let into the wool, flush,
    with one knob at its left. The letterbox readout that used to sit at its
    right is gone, because it cost the spare panel and a second firmware. The
    knob costs neither: it is an I2C encoder sharing the sensor's two pins."""
    b.part(box("Instrument band", (w, BAND_H, BAND_T), (0, cy, z_face - BAND_T / 2 + 1.0),
               b.cols["Face"], mat_alloy, bevel=0.4), layer)
    b.part(cylinder("Knob", KNOB_D / 2, KNOB_H, (knob_x, cy, z_face + KNOB_H / 2 - 1.0),
                    b.cols["Face"], mat_alloy, verts=48), layer)
    b.part(box("Knob index", (1.6, 9.0, 1.2), (knob_x, cy + 8.0, z_face + KNOB_H - 1.4),
               b.cols["Face"], mat_dark), layer)
    # the breakout itself, behind the band, so the depth is accounted for
    b.part(box("I2C encoder (Adafruit 5880)", ENCODER, (knob_x, cy, z_face - 18.0),
               b.cols["Electronics"], b.m["pcb"]), 6)


def leaf(b, name, hinge_x, hinge_y, hinge_z, width, height, angle, parent,
         mat_wood, mat_paper, toward=-1.0, layer=0):
    """One shoji leaf, hung on an empty at its hinge so it can be posed. The
    leaf is built extending from the hinge toward `toward` in x; the lattice is
    laid on the world 80 mm grid rather than the leaf's own, so bars line up
    across a closed pair and land on the panels' seams."""
    piv = bpy.data.objects.new(f"{name} hinge", None)
    bpy.context.scene.collection.objects.link(piv)
    piv.parent = parent
    piv.location = (mm(hinge_x), mm(hinge_y), mm(hinge_z))
    piv.rotation_euler = (0, math.radians(angle), 0)
    b.parts[piv.name] = (piv, layer)

    def at(x, y, z):
        return (x, y, z)

    def add(nm, size, pos, mat, bevel=0.4):
        o = box(nm, size, at(*pos), b.cols["Face"], mat, bevel=bevel)
        o.parent = piv
        b.parts[o.name] = (o, layer)
        return o

    x0 = 0.0
    x1 = toward * width
    xc = (x0 + x1) / 2
    hs = STILE_W / 2
    zc = LEAF_T / 2
    # frame: two stiles and two rails
    add(f"{name} stile hinge", (STILE_W, height, LEAF_T), (x0 + toward * hs, 0, zc), mat_wood)
    add(f"{name} stile free", (STILE_W, height, LEAF_T), (x1 - toward * hs, 0, zc), mat_wood)
    add(f"{name} rail top", (width - STILE_W * 2, STILE_W, LEAF_T),
        (xc, height / 2 - hs, zc), mat_wood)
    add(f"{name} rail bottom", (width - STILE_W * 2, STILE_W, LEAF_T),
        (xc, -height / 2 + hs, zc), mat_wood)
    # the paper, on the back of the lattice the way a shoji is papered
    add(f"{name} paper", (width - 2.0, height - 2.0, PAPER_T),
        (xc, 0, LEAF_T - KUMIKO_D - PAPER_T / 2), mat_paper, bevel=0.0)
    # kumiko, on the world 80 grid
    lo, hi = min(x0, x1), max(x0, x1)
    k = 0
    x = math.ceil((hinge_x + lo + KUMIKO) / KUMIKO) * KUMIKO
    while x < hinge_x + hi - KUMIKO / 2:
        local = x - hinge_x
        if abs(local - x0) > STILE_W and abs(local - x1) > STILE_W:
            add(f"{name} kumiko v{k}", (KUMIKO_W, height - 2 * STILE_W, KUMIKO_D),
                (local, 0, LEAF_T - KUMIKO_D / 2), mat_wood, bevel=0.2)
            k += 1
        x += KUMIKO
    y = math.ceil((hinge_y - height / 2 + KUMIKO) / KUMIKO) * KUMIKO
    j = 0
    while y < hinge_y + height / 2 - KUMIKO / 2:
        local = y - hinge_y
        if abs(abs(local) - height / 2) > STILE_W:
            add(f"{name} kumiko h{j}", (width - 2 * STILE_W, KUMIKO_W, KUMIKO_D),
                (xc, local, LEAF_T - KUMIKO_D / 2), mat_wood, bevel=0.2)
            j += 1
        y += KUMIKO
    return piv


# ================================================================== the build

class SBuild(A.Build):
    """alt_model's Build, plus the materials these three need."""

    def __init__(self, face_png, lit, cloth_name, **kw):
        self.cloth_name = cloth_name
        super().__init__(face_png, lit, cloth_name, **kw)
        self.m["walnut"] = walnut_material()
        self.m["lining"] = lining_material(self.cloth_name, A.CLOTH[self.cloth_name])
        self.m["paper"] = paper_material()
        self.m["graphite"] = A.board_material("Graphite", (0.028, 0.028, 0.030), 0.80)
        # A flat brushed plate facing the room mirrors the room, and the studio is
        # dark, so at 0.28 the band rendered as a black slot. 0.42 with almost no
        # anisotropy holds a diffuse sheen and still reads as machined metal.
        self.m["satin"] = W.brushed_material("Satin alloy", (0.82, 0.825, 0.84), 0.42, 0.12)
        # The 35 percent grey the rest of the project uses is right when the
        # only thing behind it is a lit picture. Over a wool field it is not:
        # at that tint the oatmeal rendered as pure black and the whole point
        # of a single glazed face went with it. A light smoke, nearer picture
        # glazing than sunglasses, is what this one wants.
        self.m["lightsmoke"] = material("Light smoke acrylic", (0.72, 0.72, 0.73),
                                        0.02, transmission=1.0, ior=1.49)


# ================================================================== designs

def alcove(b):
    """Walnut, and the picture at the bottom of a splayed wool well.

    Vitrine's recess is the strongest single idea in the six, because it stops
    the picture being on the wall and starts it being inside something. It had
    one fault, the viewing angle, and splaying the walls 11.3 degrees fixes it.
    Around that: the first walnut frame's mitred body, tapered toward the wall
    the way Soft Monument's silhouette refuses to be a plain box; Index's
    graphite-and-alloy discipline at the aperture; Console's bottom weighting
    and its band; and the boxed enclosure's closed, vented, wall-padded back.
    """
    MAT_S, MAT_T, MAT_B = 44.0, 30.0, 130.0        # wool around the mouth
    mat_w = WELL_OUT + 2 * MAT_S                   # 588
    mat_h = WELL_OUT + MAT_T + MAT_B               # 660
    FACE_W = 22.0                                  # walnut face width
    out_w, out_h = mat_w + 2 * FACE_W, mat_h + 2 * FACE_W      # 632 x 704
    cy = -(MAT_B - MAT_T) / 2                      # the picture rides high: -50
    z_glass_f = AIR + ACR_T                        # 9.875
    z_mat = z_glass_f + WELL_D                     # 49.875: the wool face
    z_wood = z_mat + 5.0                           # the wood stands 5 proud

    b.panels()
    z_wall = body(b, mat_w, mat_h, mat_w - 92, mat_h - 92, cy, b.m["black"],
                  halo_strength=34.0)
    b.glass(GLASS)
    # the well: wool all the way down, so the picture sits in a soft room
    well(b, "Well", WELL_OUT, WELL_IN, z_mat, z_glass_f, b.m["lining"], thickness=5.0)
    holed_plate(b, "Mat", mat_w, mat_h, 3.0, z_mat - 3.0, WELL_OUT, 0, cy, 0, 0,
                b.m["cloth"])
    # the wool has to reach the board, or the mat floats over a void: the side
    # render of the first alternates found that the hard way
    for i, (dx, dy, sx, sy) in enumerate((
            (0, mat_h / 2 - 12, mat_w, 24), (0, -mat_h / 2 + 12, mat_w, 24),
            (-mat_w / 2 + 12, 0, 24, mat_h - 48), (mat_w / 2 - 12, 0, 24, mat_h - 48))):
        h = z_mat - 3.0 - Z_STEEL_FRONT
        b.part(box(f"Surround {i}", (sx, sy, h), (dx, cy + dy, Z_STEEL_FRONT + h / 2),
                   b.cols["Face"], b.m["cloth"], bevel=0.6), 2)
    bezel(b, "Bezel", BEZEL_OPEN, z_glass_f + 2.0, 5.0, b.m["satin"], face=BEZEL_FACE)
    frame(b, "Walnut", out_w, out_h, FACE_W, z_wood, Z_PLY_BACK - 2.0, 0, cy,
          b.m["walnut"], taper=6.0)
    band(b, mat_w - 40, cy - mat_h / 2 + MAT_B / 2, z_mat, -mat_w / 2 + 90,
         b.m["satin"], b.m["graphite"])
    # under the bottom rail, right of the knob: the hand that reaches for the
    # band from below finds the switch on the way
    b.mains((150.0, cy - out_h / 2 + FACE_W / 2, z_wood - 60.0), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, cy - 190.0), bars=(-176.0, cy + 150.0),
                  fuse=(-40.0, cy + 46.0), pi=(186.0, cy + 150.0), seat=Z_PLY_BACK)
    return dict(w=out_w, h=out_h, front=z_wood, back=z_wall, height=1500.0,
                label="Alcove", centre_y=cy)


def fascia(b):
    """One sheet of glass over everything, and the machine behind it.

    Index's argument is that this should look like a piece of audio equipment
    and get there through tight seams and proportion rather than features. So:
    a single smoked sheet edge to edge, a wool field behind it with the picture
    let into a 12 mm graphite reveal, a satin alloy case holding the glass, and
    black walnut cheeks after the Braun SK4, where a metal body and wooden side
    panels were the whole material argument. Soft Monument's chamfer becomes
    the cheeks' rake back to the wall. Console's band becomes the rail you
    reach under, carrying the knob and, on its underside, the switch. The wool
    is inside the glass, which answers Soft Monument's own stated fault: it is
    the design that collects the most dust.
    """
    F_S, F_T, F_B = 50.0, 40.0, 130.0
    fld_w = FACE + 2 * F_S                         # 580
    fld_h = FACE + F_T + F_B                       # 650
    cy = -(F_B - F_T) / 2                          # -45
    CHEEK = 28.0
    RAIL_H = 40.0
    RAIL_D = 64.0
    ANGLE = 6.0                                    # the alloy case's face
    z_field = 12.0                                 # the wool, 12 in front of the LEDs
    z_glass_b = z_field + 2.0
    z_glass_f = z_glass_b + ACR_T                  # 17.175
    out_w = fld_w + 2 * ANGLE + 2 * CHEEK          # 624
    case_h = fld_h + 2 * ANGLE                     # 662
    out_h = case_h + RAIL_H                        # 702
    rail_cy = cy - case_h / 2 - RAIL_H / 2

    b.panels()
    z_wall = body(b, fld_w, fld_h, fld_w - 92, fld_h - 92, cy, b.m["black"],
                  halo_strength=30.0)
    # the wool field, on a sub-frame, with the picture 12 mm below it
    holed_plate(b, "Field", fld_w, fld_h, 3.0, z_field - 3.0, BEZEL_OPEN, 0, cy, 0, 0,
                b.m["cloth"])
    for i, (dx, dy, sx, sy) in enumerate((
            (0, fld_h / 2 - 12, fld_w, 24), (0, -fld_h / 2 + 12, fld_w, 24),
            (-fld_w / 2 + 12, 0, 24, fld_h - 48), (fld_w / 2 - 12, 0, 24, fld_h - 48))):
        h = z_field - 3.0 - Z_STEEL_FRONT
        b.part(box(f"Surround {i}", (sx, sy, h), (dx, cy + dy, Z_STEEL_FRONT + h / 2),
                   b.cols["Face"], b.m["cloth"], bevel=0.6), 2)
    # the reveal: Index's narrow graphite line, read as a depth rather than a
    # drawn edge. Straight walls, not splayed: this one is flush and precise
    well(b, "Reveal", BEZEL_OPEN, BEZEL_OPEN, z_field - 3.0, 0.6, b.m["graphite"],
         thickness=3.0)
    b.part(box("Light smoke acrylic", (fld_w, fld_h, ACR_T), (0, cy, z_glass_b + ACR_T / 2),
               b.cols["Face"], b.m["lightsmoke"], bevel=0.4), 1)
    # the case: alloy angle over the glass edge on all four sides
    for i, (dx, dy, sx, sy) in enumerate((
            (0, fld_h / 2 + ANGLE / 2, fld_w + 2 * ANGLE, ANGLE),
            (0, -fld_h / 2 - ANGLE / 2, fld_w + 2 * ANGLE, ANGLE),
            (-fld_w / 2 - ANGLE / 2, 0, ANGLE, fld_h),
            (fld_w / 2 + ANGLE / 2, 0, ANGLE, fld_h))):
        b.part(box(f"Case {i}", (sx, sy, z_glass_f - Z_STEEL_FRONT),
                   (dx, cy + dy, (z_glass_f + Z_STEEL_FRONT) / 2),
                   b.cols["Face"], b.m["satin"], bevel=0.4), 1)
    # walnut cheeks, raked back so the body reads thinner than its 126 mm
    for i, sx in enumerate((-1, 1)):
        x = sx * (fld_w / 2 + ANGLE + CHEEK / 2)
        d = z_glass_f - (Z_PLY_BACK - CAVITY - BACK_T)
        o = b.part(box(f"Cheek {i}", (CHEEK, out_h, d),
                       (x, cy - RAIL_H / 2, z_glass_f - d / 2),
                       b.cols["Body"], b.m["walnut"], bevel=0.8), 0)
        for v in o.data.vertices:                    # rake the outer face back
            if (v.co.x > 0) == (sx > 0) and v.co.z < 0:
                v.co.x -= math.copysign(mm(29.0), sx)
    # the rail: satin alloy, full width, the knob on its face and the switch
    # under it. One horizontal element carries everything the hand does
    b.part(box("Rail", (out_w, RAIL_H, RAIL_D), (0, rail_cy, z_glass_f - RAIL_D / 2),
               b.cols["Body"], b.m["satin"], bevel=1.0), 0)
    b.part(cylinder("Knob", KNOB_D / 2, KNOB_H, (-out_w / 2 + 76, rail_cy, z_glass_f + KNOB_H / 2 - 2),
                    b.cols["Face"], b.m["satin"], verts=48), 1)
    b.part(box("Knob index", (1.6, 9.0, 1.2), (-out_w / 2 + 76, rail_cy + 8.0,
                                               z_glass_f + KNOB_H - 2.4), b.cols["Face"],
               b.m["graphite"]), 1)
    b.part(box("I2C encoder (Adafruit 5880)", ENCODER,
               (-out_w / 2 + 76, rail_cy, z_glass_f - 22.0), b.cols["Electronics"],
               b.m["pcb"]), 6)
    b.mains((176.0, rail_cy - RAIL_H / 2, z_glass_f - RAIL_D / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, cy - 186.0), bars=(-172.0, cy + 148.0),
                  fuse=(-38.0, cy + 44.0), pi=(182.0, cy + 148.0), seat=Z_PLY_BACK)
    return dict(w=out_w, h=out_h, front=z_glass_f, back=z_wall, height=1500.0,
                label="Fascia", centre_y=cy - RAIL_H / 2)


def shutter(b, state="open"):
    """Four shoji leaves that fold across the picture, and opening them is the
    switch.

    A winged altarpiece has a weekday side and a feast-day side: shut through
    Lent and ordinary time, opened for feasts, and Pacher's St Wolfgang has
    three states because it has two layers of wing. The Lenten veil is the
    same instinct with no picture at all, a cloth hung to give a fast of the
    eyes. Bang and Olufsen's Beovision Harmony is the living version, wooden
    covers that fold away as the screen rises.

    None of the other objects has an off state that is a different object.
    This one does. Closed, the album is behind laminated washi on an 80 mm
    kumiko grid, so what reaches the room is the record's colour and not the
    record's picture, which is Noguchi's argument for Akari: light as the
    sculpture. Folded back, it is nine panels and a bright edge.

    And the leaves are the control. Fukasawa's rule is that a thing on a wall
    should ask for one honest gesture and that the gesture should be the one
    the form already suggests. You open it to look at it.
    """
    MAT_S, MAT_T, MAT_B = 80.0, 80.0, 160.0
    open_w = FACE + 2 * MAT_S                      # 640
    open_h = FACE + MAT_T + MAT_B                  # 720
    FACE_W = 20.0
    out_w, out_h = open_w + 2 * FACE_W, open_h + 2 * FACE_W    # 680 x 760
    cy = -(MAT_B - MAT_T) / 2                      # -40
    z_glass_f = AIR + ACR_T
    z_mat = 12.0
    z_wood = 18.0                                  # the leaves close on this

    b.panels()
    z_wall = body(b, open_w, open_h, open_w - 110, open_h - 110, cy, b.m["black"],
                  halo_strength=26.0)
    b.glass(GLASS)
    holed_plate(b, "Mat", open_w, open_h, 3.0, z_mat - 3.0, BEZEL_OPEN, 0, cy, 0, 0,
                b.m["cloth"])
    for i, (dx, dy, sx, sy) in enumerate((
            (0, open_h / 2 - 12, open_w, 24), (0, -open_h / 2 + 12, open_w, 24),
            (-open_w / 2 + 12, 0, 24, open_h - 48), (open_w / 2 - 12, 0, 24, open_h - 48))):
        h = z_mat - 3.0 - Z_STEEL_FRONT
        b.part(box(f"Surround {i}", (sx, sy, h), (dx, cy + dy, Z_STEEL_FRONT + h / 2),
                   b.cols["Face"], b.m["cloth"], bevel=0.6), 2)
    bezel(b, "Bezel", BEZEL_OPEN, z_glass_f + 2.0, 5.0, b.m["satin"], face=BEZEL_FACE)
    frame(b, "Walnut", out_w, out_h, FACE_W, z_wood, Z_PLY_BACK - 2.0, 0, cy,
          b.m["walnut"], taper=6.0)

    # Two leaves, each two panels wide, hinged on the case's outer edges. Four
    # bi-folding leaves were tried first because they halve the wall the object
    # claims when it is open, and they were wrong: a folding pair needs its own
    # stile on both sides of every joint, so four leaves put three 36 mm bands
    # of solid walnut across a 640 mm face and the thing read as a window
    # grille. Two leaves put one joint down the middle, which is the altarpiece
    # anyway. The wall it claims when open is the price, and it is stated.
    #
    # The lattice registers to the panel grid in both axes: on an 80 mm pitch
    # the vertical bars land at 80 (both seams), 160 (mid panel) and 240 (the
    # picture's edge), and the horizontal bars at the same three.
    LW, LH = open_w / 2, open_h + 20.0
    poses = {"closed": (0.0, 0.0), "half": (-165.0, 0.0), "open": (-170.0, 170.0)}
    a_l, a_r = poses[state]
    hy, hz = cy, z_wood
    leaf(b, "Leaf L", -open_w / 2, hy, hz, LW, LH, a_l, b.root,
         b.m["walnut"], b.m["paper"], toward=+1.0)
    leaf(b, "Leaf R", open_w / 2, hy, hz, LW, LH, a_r, b.root,
         b.m["walnut"], b.m["paper"], toward=-1.0)
    # the reed: the one thing that turns a gesture into a signal. Both meeting
    # stiles carry a magnet; the switch sits behind the mat at the centre and
    # reads through it. It is not on GPIO, because there is none: it goes to a
    # small I2C expander on the sensors' bus
    b.part(box("Reed switch", (14.0, 3.0, 3.0), (0, cy + open_h / 2 - 30, z_mat - 8.0),
               b.cols["Electronics"], b.m["black"]), 6)

    b.mains((180.0, cy - out_h / 2 + FACE_W / 2, z_wood - 58.0), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, cy - 220.0), bars=(-190.0, cy + 180.0),
                  fuse=(-44.0, cy + 60.0), pi=(200.0, cy + 180.0), seat=Z_PLY_BACK)
    front = z_wood + LEAF_T if state == "closed" else z_wood
    width = out_w if state == "closed" else out_w + 2 * LW
    # Closed, the object is a lantern, and a lantern photographed under a full
    # studio key is just a box. The paper only argues for itself when the room
    # is darker than the thing in it.
    lights = (0.12, 0.12, 0.30) if state == "closed" else (1.0, 1.0, 1.0)
    return dict(w=width, h=out_h, front=front, back=z_wall, height=1500.0,
                label="Shutter", centre_y=cy, lights=lights)


DESIGNS = {"alcove": alcove, "fascia": fascia, "shutter": shutter}
DEFAULT_CLOTH = {"alcove": "charcoal", "fascia": "chalk", "shutter": "charcoal"}


# ==================================================================== main

def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="design/renders")
    ap.add_argument("--face", default="")
    ap.add_argument("--samples", type=int, default=180)
    ap.add_argument("--design", default="alcove", choices=sorted(DESIGNS))
    ap.add_argument("--cloth", default="")
    ap.add_argument("--state", default="open", choices=("closed", "half", "open"))
    ap.add_argument("--views", default="hero,front,side,detail,off")
    ap.add_argument("--prefix", default="")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    prefix = args.prefix or args.design
    face = os.path.abspath(args.face) if args.face else ""
    views = args.views.split(",")
    cloth = args.cloth or DEFAULT_CLOTH[args.design]

    def scene(lit=True):
        b = SBuild(face, lit, cloth)
        fn = DESIGNS[args.design]
        info = fn(b, args.state) if args.design == "shutter" else fn(b)
        b.place(info["back"], info["height"])
        b.studio()
        ks, fs, rs = info.get("lights", (1.0, 1.0, 1.0))
        b.lights["key"].data.energy *= ks
        b.lights["fill"].data.energy *= fs
        b.lights["rim"].data.energy *= rs
        b.inlet_world = (mm(b.inlet_at[0]), b.wall_y - mm(b.inlet_at[2]),
                         mm(info["height"]) + mm(b.inlet_at[1]))
        return b, info

    b, info = scene(True)
    W.glare(b.sc)
    cy = info.get("centre_y", 0.0)
    C = (0.0, b.wall_y - mm(info["front"]) * 0.5, mm(info["height"]) + mm(cy))
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
    if "detail" in views:
        t = b.inlet_world
        W.aim(b.cam, (t[0] + 0.10, t[1] - 0.36, t[2] + 0.20), t, lens=60, fstop=5.6, focus=t)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-detail.png"), args.samples)
    if "corner" in views:
        k = (-mm(info["w"]) / 2 + 0.06, b.wall_y - mm(info["front"]),
             mm(info["height"]) + mm(cy) + mm(info["h"]) / 2 - 0.06)
        W.aim(b.cam, (k[0] - 0.22, k[1] - 0.30, k[2] + 0.12), k, lens=85, fstop=5.6, focus=k)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-corner.png"), args.samples)
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
        b.lights["key"].data.energy = 460
        b.lights["fill"].data.energy = 200
        C = (0.0, b.wall_y - mm(info["front"]) * 0.5,
             mm(info["height"]) + mm(info.get("centre_y", 0.0)))
        W.aim(b.cam, (-span * 1.15, -span * 2.4, C[2] + span * 0.22), C, lens=55, fstop=4.5)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-off.png"), args.samples)

    print("design %s, cloth %s%s" % (args.design, cloth,
                                     ", %s" % args.state if args.design == "shutter" else ""))
    print("envelope %.0f x %.0f mm, %.1f mm front to back"
          % (info["w"], info["h"], info["front"] - info["back"]))
    print("mains module at local x %.0f y %.0f z %.0f"
          % (b.inlet_at[0], b.inlet_at[1], b.inlet_at[2]))


if __name__ == "__main__":
    main()
