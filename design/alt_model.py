"""The alternates: one body, four ways of treating its face.

Everything the questionnaire settled is here. A fabric-wrapped front mask with
a machined chamfer, a 40 mm instrument lip carrying one real control and a
letterbox readout, a halo that samples the artwork's own edges and throws them
back at the wall, and a body that is bottom-weighted the way a picture framer
weights a mat.

    console    a plain 500 mm window, the picture behind smoked acrylic
    vitrine    the same window pushed 40 mm back, its reveal lined in cloth
    instrument the same window with the fixings shown and labelled
    nonet      nine windows on the panel pitch, the grid made the subject

Numbers come from wall_model.py wherever they were already verified there, so
there is one home for the panel, the magnet, the supply and the bonnet. What
is new is at the top of this file with the same VERIFIED / LISTING / TYPICAL /
DESIGN marks.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python design/alt_model.py -- --direction nonet --palette oxblood \
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
from wall_model import mm, box, cylinder, material, collection, link, cable

# ============================================================ new numbers
BOARD_W = 609.6                # LISTING   still one 24 in sheet wide
BOTTOM = 185.0                 # DESIGN    a bottom-weighted mat, the way a
                               #           framer weights one. It has to clear
                               #           a 160 mm panel standing below the
                               #           aperture, which sets the minimum at
                               #           175; 185 leaves 12 mm of margin
BOARD_H = W.BORDER + W.FACE + BOTTOM        # 709.6, cut from the 2 x 4 ft sheet
STEEL_W = STEEL_H = 609.6      # LISTING   the steel stays a 24 in square; the
                               #           bottom zone carries no magnets
LIP_H = 40.0                   # DESIGN    the instrument band
MASK_T = 3.0                   # LISTING   1/8 in ply or ABS, fabric wrapped
APERTURE = 500.0               # DESIGN    the single window
NONET_AP = 152.0               # DESIGN    nine windows on the 160 panel pitch,
NONET_LAND = W.PANEL - NONET_AP             # 8 mm of cloth over every seam
CHAMFER = 3.0                  # DESIGN    the machined edge, the bright line
KNOB_D, KNOB_H = 34.0, 19.0    # LISTING   rotary encoder plus an alloy knob
WIN = (160.0, 30.0)            # DESIGN    the readout window: a whole panel
                               #           wide, twelve pixel rows tall
RECESS = 40.0                  # DESIGN    how far vitrine sinks its window
HALO_INSET = 12.0              # DESIGN    close to the edge, or the body\n                               #           shadows its own light
HALO_SEGS = 3                  # DESIGN    three colour zones an edge, one to
HALO_SUB = 3                   #           each panel, but split three ways so
                               #           the wall gets a wash and not three
                               #           hot spots
FASTENER_D = 4.0               # DESIGN    instrument only: the shown fixings

# depth, from the LED face at z = 0 going back
Z_PANEL_BACK = -W.PANEL_T
Z_STEEL_FRONT = Z_PANEL_BACK - W.MAG_FOOT_H
Z_STEEL_BACK = Z_STEEL_FRONT - W.STEEL_T
Z_PLY_BACK = Z_STEEL_BACK - W.PLY_T
AIR = 6.7                      # the glass over the LEDs, as wall_model has it


def palette(name):
    """Fabric, body and edge. The body is black in every one of them: the
    cloth is where the colour goes, because cloth reads as considered and
    paint reads as painted."""
    cloth = {
        "charcoal": (0.055, 0.055, 0.058),
        "oatmeal": (0.360, 0.320, 0.258),
        "oxblood": (0.115, 0.028, 0.030),
        "forest": (0.028, 0.070, 0.052),
        "ink": (0.021, 0.030, 0.062),
    }[name]
    return cloth


def fabric_material(name, base):
    """Wool cloth: rough, no specular to speak of, and a fine weave in the
    normal. The bump is what stops it reading as flat paint in a render."""
    m, nt, b = W.principled(f"Cloth {name}")
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Roughness"].default_value = 0.95
    if "Sheen Weight" in b.inputs:
        b.inputs["Sheen Weight"].default_value = 0.35
        b.inputs["Sheen Roughness"].default_value = 0.4
    b.inputs["Specular IOR Level"].default_value = 0.18
    tex = nt.nodes.new("ShaderNodeTexCoord")
    # two crossed band textures are a weave; one noise on top stops it
    # reading as corduroy. Object coordinates, so the scale is in metres.
    warp = nt.nodes.new("ShaderNodeTexWave")
    warp.wave_type, warp.bands_direction = "BANDS", "X"
    warp.inputs["Scale"].default_value = 260.0
    weft = nt.nodes.new("ShaderNodeTexWave")
    weft.wave_type, weft.bands_direction = "BANDS", "Y"
    weft.inputs["Scale"].default_value = 260.0
    for n_ in (warp, weft):
        nt.links.new(tex.outputs["Object"], n_.inputs["Vector"])
    mixw = nt.nodes.new("ShaderNodeMix")
    mixw.data_type, mixw.blend_type = "RGBA", "OVERLAY"
    mixw.inputs["Factor"].default_value = 1.0
    nt.links.new(warp.outputs["Color"], mixw.inputs[6])
    nt.links.new(weft.outputs["Color"], mixw.inputs[7])
    fuzz = nt.nodes.new("ShaderNodeTexNoise")
    fuzz.inputs["Scale"].default_value = 900.0
    fuzz.inputs["Detail"].default_value = 4.0
    nt.links.new(tex.outputs["Object"], fuzz.inputs["Vector"])
    fine = nt.nodes.new("ShaderNodeBump")
    fine.inputs["Strength"].default_value = 0.35
    fine.inputs["Distance"].default_value = 0.4
    nt.links.new(fuzz.outputs["Fac"], fine.inputs["Height"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.75
    bump.inputs["Distance"].default_value = 0.9
    nt.links.new(mixw.outputs[2], bump.inputs["Height"])
    nt.links.new(fine.outputs["Normal"], bump.inputs["Normal"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    # the weave darkens where the threads dip, which is most of what sells it
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*[c * 0.62 for c in base], 1.0)
    ramp.color_ramp.elements[1].color = (*[min(1.0, c * 1.22) for c in base], 1.0)
    nt.links.new(mixw.outputs[2], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
    return m


def readout_material():
    """The letterbox window: amber, on the same 2.5 mm pitch as everything
    else, showing a level meter and a line of text. Drawn procedurally so it
    never has to be a picture file."""
    m, nt, b = W.principled("Readout")
    b.inputs["Base Color"].default_value = (0.010, 0.010, 0.010, 1)
    b.inputs["Roughness"].default_value = 0.45
    tex = nt.nodes.new("ShaderNodeTexCoord")
    scale = nt.nodes.new("ShaderNodeVectorMath")
    scale.operation = "SCALE"
    scale.inputs["Scale"].default_value = 64.0
    nt.links.new(tex.outputs["UV"], scale.inputs[0])
    frac = nt.nodes.new("ShaderNodeVectorMath")
    frac.operation = "FRACTION"
    nt.links.new(scale.outputs[0], frac.inputs[0])
    ctr = nt.nodes.new("ShaderNodeVectorMath")
    ctr.operation = "SUBTRACT"
    ctr.inputs[1].default_value = (0.5, 0.5, 0.0)
    nt.links.new(frac.outputs[0], ctr.inputs[0])
    ln = nt.nodes.new("ShaderNodeVectorMath")
    ln.operation = "LENGTH"
    nt.links.new(ctr.outputs[0], ln.inputs[0])
    disc = nt.nodes.new("ShaderNodeMath")
    disc.operation = "LESS_THAN"
    disc.inputs[1].default_value = 0.36
    nt.links.new(ln.outputs["Value"], disc.inputs[0])
    # a bar that falls away to the right, and a quiet band of text under it
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(scale.outputs[0], sep.inputs[0])
    bar = nt.nodes.new("ShaderNodeMath")      # one lit row along the bottom
    bar.operation = "LESS_THAN"
    bar.inputs[1].default_value = 1.0
    nt.links.new(sep.outputs["Y"], bar.inputs[0])
    # a level meter: columns of decreasing height, with a gap every fourth
    # pixel so it reads as discrete bars rather than a wedge
    uvsep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tex.outputs["UV"], uvsep.inputs[0])
    wob = nt.nodes.new("ShaderNodeTexNoise")
    wob.inputs["Scale"].default_value = 14.0
    wob.inputs["Detail"].default_value = 0.0
    nt.links.new(tex.outputs["UV"], wob.inputs["Vector"])
    # a spectrum across the whole window rather than a ramp: every column
    # has its own level, which is what a meter looks like
    span = nt.nodes.new("ShaderNodeMath")
    span.operation = "MULTIPLY"
    span.inputs[1].default_value = 0.62
    nt.links.new(wob.outputs["Fac"], span.inputs[0])
    height = nt.nodes.new("ShaderNodeMath")
    height.operation = "ADD"
    height.inputs[1].default_value = 0.30
    nt.links.new(span.outputs[0], height.inputs[0])
    lvl = nt.nodes.new("ShaderNodeMath")
    lvl.operation = "LESS_THAN"
    nt.links.new(uvsep.outputs["Y"], lvl.inputs[0])
    nt.links.new(height.outputs[0], lvl.inputs[1])
    colmod = nt.nodes.new("ShaderNodeMath")
    colmod.operation = "MODULO"
    colmod.inputs[1].default_value = 4.0
    nt.links.new(sep.outputs["X"], colmod.inputs[0])
    gap = nt.nodes.new("ShaderNodeMath")
    gap.operation = "LESS_THAN"
    gap.inputs[1].default_value = 3.0
    nt.links.new(colmod.outputs[0], gap.inputs[0])
    meter = nt.nodes.new("ShaderNodeMath")
    meter.operation = "MULTIPLY"
    nt.links.new(lvl.outputs[0], meter.inputs[0])
    nt.links.new(gap.outputs[0], meter.inputs[1])
    with_base = nt.nodes.new("ShaderNodeMath")
    with_base.operation = "MAXIMUM"
    nt.links.new(meter.outputs[0], with_base.inputs[0])
    nt.links.new(bar.outputs[0], with_base.inputs[1])
    on = nt.nodes.new("ShaderNodeMath")
    on.operation = "MULTIPLY"
    nt.links.new(with_base.outputs[0], on.inputs[0])
    nt.links.new(disc.outputs[0], on.inputs[1])
    amber = nt.nodes.new("ShaderNodeMix")
    amber.data_type, amber.blend_type = "RGBA", "MULTIPLY"
    amber.inputs["Factor"].default_value = 1.0
    amber.inputs[6].default_value = (1.0, 0.46, 0.06, 1.0)
    grey = nt.nodes.new("ShaderNodeCombineColor")
    for k in range(3):
        nt.links.new(on.outputs[0], grey.inputs[k])
    nt.links.new(grey.outputs[0], amber.inputs[7])
    nt.links.new(amber.outputs[2], b.inputs["Emission Color"])
    b.inputs["Emission Strength"].default_value = 15.0
    return m


def halo_colours(face_png):
    """Twelve segments, three to an edge, each the average of the artwork's
    own outer strip. This is what makes the wall behind the object read as a
    continuation of the record sleeve rather than as mood lighting."""
    flat = [(0.5, 0.5, 0.5)] * 12
    if not (face_png and os.path.exists(face_png)):
        return flat
    img = bpy.data.images.load(face_png)
    w, h = img.size
    if w < 8 or h < 8:
        return flat
    px = list(img.pixels)
    d = max(4, w // 10)

    def avg(x0, x1, y0, y1):
        r = g = b = 0.0
        n = 0
        for y in range(max(0, y0), min(h, y1)):
            row = y * w
            for x in range(max(0, x0), min(w, x1)):
                i = (row + x) * 4
                r += px[i]; g += px[i + 1]; b += px[i + 2]
                n += 1
        if not n:
            return (0.5, 0.5, 0.5)
        r, g, b = r / n, g / n, b / n
        # lift and saturate a little: an average is always duller than the
        # picture it came from, and a dull halo just looks like a fault
        mx = max(r, g, b, 1e-6)
        lift = min(1.0, 0.35 + mx) / mx
        mid = (r + g + b) / 3.0
        return tuple(min(1.0, mid + (c - mid) * 1.45) * lift for c in (r, g, b))

    out = []
    third = [(0, w // 3), (w // 3, 2 * w // 3), (2 * w // 3, w)]
    for a, b_ in third:                       # bottom, left to right
        out.append(avg(a, b_, 0, d))
    for a, b_ in third:                       # right, bottom to top
        out.append(avg(w - d, w, a, b_))
    for a, b_ in reversed(third):             # top, right to left
        out.append(avg(a, b_, h - d, h))
    for a, b_ in reversed(third):             # left, top to bottom
        out.append(avg(0, d, a, b_))
    bpy.data.images.remove(img)
    return out


# ==================================================================== build

def build(direction, pal, face_png, lit=True):
    sc = W.clean()
    root = bpy.data.objects.new("Alt", None)
    sc.collection.objects.link(root)
    root.rotation_euler = (math.pi / 2, 0, 0)
    PAD = 45.0                     # DESIGN  the halo needs room to become a
                                   #         wash rather than a bright line
    z_wall = Z_PLY_BACK - W.FURRING_D - W.BACK_T - PAD
    root.location = (0, mm(-z_wall), mm(W.WALL_H))

    cols = {n: collection(n) for n in
            ("Panels", "Face", "Board", "Halo", "Electronics", "Wiring", "Studio")}
    parts = {}

    def part(o, layer=0):
        o.parent = root
        parts[o.name] = (o, layer)
        return o

    CUT = collection("Cutters")
    CUT.hide_render = True

    cloth = fabric_material("surround", palette(pal))
    paint = material("Matte black paint", (0.016, 0.016, 0.017), 0.82)
    ply = W.plywood_material()
    alu = W.brushed_material("Alloy", (0.80, 0.805, 0.82), 0.33, 0.20)
    anod = W.brushed_material("Black anodised", (0.045, 0.045, 0.048), 0.36, 0.5)
    tin = W.brushed_material("Tinned copper", (0.75, 0.76, 0.74), 0.35)
    pcb_dark = material("PCB dark", (0.012, 0.03, 0.02), 0.5)
    black = material("Panel plastic", (0.02, 0.02, 0.02), 0.55)
    white = material("White plastic", (0.85, 0.85, 0.82), 0.5)
    red = material("Red lead", (0.55, 0.03, 0.02), 0.5)
    blk = material("Black lead", (0.012, 0.012, 0.012), 0.5)
    smoke = material("Smoked acrylic", (0.30, 0.30, 0.32), 0.02, transmission=1.0, ior=1.49)
    led = W.led_material(face_png)
    if not lit:
        led.node_tree.nodes["Principled BSDF"].inputs["Emission Strength"].default_value = 0.0

    recess = RECESS if direction == "vitrine" else 0.0
    z_acr_back = AIR + recess
    z_acr_front = z_acr_back + W.ACR_T
    z_mask_back = z_acr_front
    z_mask_front = z_mask_back + MASK_T

    hw, hh = BOARD_W / 2, BOARD_H / 2
    pic_cy = hh - W.BORDER - W.FACE / 2                    # +50
    half = W.FACE / 2
    lip_cy = -hh + 60.0                                    # the alloy band
    win_c = (210.0, lip_cy)
    knob_c = (-205.0, lip_cy)

    # ---- the carcass ------------------------------------------------------
    part(box("Plywood board", (BOARD_W, BOARD_H, W.PLY_T), (0, 0, Z_STEEL_BACK - W.PLY_T / 2),
             cols["Board"], paint, bevel=0.6), 5)
    part(box("Steel skin", (STEEL_W, 490.0, W.STEEL_T), (0, pic_cy, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2),
             cols["Board"], paint), 5)

    # the openings, one behind each panel, three of them slotted for a plug
    z_cut = (Z_STEEL_FRONT + Z_PLY_BACK) / 2
    d_cut = W.STEEL_T + W.PLY_T + 6
    for r in range(3):
        for c in range(3):
            cx = -half + W.PANEL / 2 + c * W.PANEL
            cy = pic_cy + half - W.PANEL / 2 - r * W.PANEL
            if c == W.CHAIN_START_COL:
                w = W.SLOT_L - W.HOLE_D
                part(box(f"Slot {r}{c}", (w, W.HOLE_D, d_cut), (cx, cy, z_cut), CUT), 5)
                for j, dx in enumerate((-w / 2, w / 2)):
                    part(cylinder(f"Slot {r}{c} end {j}", W.HOLE_D / 2, d_cut, (cx + dx, cy, z_cut), CUT), 5)
            else:
                part(cylinder(f"Hole {r}{c}", W.HOLE_D / 2, d_cut, (cx, cy, z_cut), CUT), 5)
    for o in CUT.objects:
        o.display_type = "WIRE"
    for name in ("Plywood board", "Steel skin"):
        m = parts[name][0].modifiers.new("Openings", "BOOLEAN")
        m.operation, m.operand_type, m.collection, m.solver = "DIFFERENCE", "COLLECTION", CUT, "EXACT"

    # ---- nine panels on their magnets ------------------------------------
    for r in range(3):
        for c in range(3):
            cx = -half + W.PANEL / 2 + c * W.PANEL
            cy = pic_cy + half - W.PANEL / 2 - r * W.PANEL
            n = r * 3 + c + 1
            part(box(f"Panel {n} PCB", (W.PANEL - 0.4, W.PANEL - 0.4, 1.6), (cx, cy, -0.8),
                     cols["Panels"], pcb_dark), 3)
            bpy.ops.mesh.primitive_plane_add(size=1.0)
            face = bpy.context.active_object
            face.name = f"Panel {n} LEDs"
            face.scale = (mm(W.PANEL), mm(W.PANEL), 1)
            bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
            face.location = (mm(cx), mm(cy), mm(0.15))
            W.uv_square(face, c / 3, (2 - r) / 3, (c + 1) / 3, (3 - r) / 3)
            face.data.materials.append(led)
            link(face, cols["Panels"])
            part(face, 3)
            zb = -W.PANEL_T + 5.5
            for k, dx in enumerate((48, -48)):
                part(box(f"Panel {n} HUB75 {'in' if k == 0 else 'out'}", W.IDC,
                         (cx + dx, cy + 44, zb), cols["Panels"], black), 3)
            part(box(f"Panel {n} VH4", (12.0, 9.0, 8.0), (cx, cy - 58, zb), cols["Panels"], white), 3)
            for k, (mx, my) in enumerate((W.PANEL_M3[0], W.PANEL_M3[1], W.PANEL_M3[6], W.PANEL_M3[7])):
                part(cylinder(f"Panel {n} magnet {k}", W.MAG_D / 2, W.MAG_FOOT_H,
                              (cx + mx, cy + my, -W.PANEL_T - W.MAG_FOOT_H / 2),
                              cols["Panels"], tin, verts=24), 3)
    W.borrow("P Panels", root, parts, 3,
             keep=lambda n: "PCB face" not in n and "emitters" not in n)
    at = bpy.data.objects.get("Atelier P Panels")
    if at:                                                  # its grid centres on 0
        at.location.z += mm(-pic_cy)

    # ---- the tenth panel: the readout, on the front, in the bottom zone ---
    rp = (win_c[0], -hh + W.PANEL / 2 + 2.4)
    part(box("Readout panel PCB", (W.PANEL, W.PANEL, 1.6), (rp[0], rp[1], -0.8),
             cols["Panels"], pcb_dark), 3)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    rf = bpy.context.active_object
    rf.name = "Readout LEDs"
    rf.scale = (mm(W.PANEL), mm(W.PANEL), 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    rf.location = (mm(rp[0]), mm(rp[1]), mm(0.15))
    W.uv_square(rf, 0.0, 0.0, 1.0, 1.0)
    rf.data.materials.append(readout_material())
    link(rf, cols["Panels"])
    part(rf, 3)

    # ---- the face: acrylic, a fabric mask, an alloy lip -------------------
    F = cols["Face"]
    MCUT = collection("Cutters face")
    MCUT.hide_render = True

    def ring(name, cx, cy, size, w, t, z, mat):
        """The machined edge, as a part rather than a bevel: a fine alloy
        frame standing in the opening. One millimetre of bright line is what
        does the work at two metres."""
        half_o = size / 2 + w / 2
        for i, (dx, dy, sx, sy) in enumerate((
                (0, half_o, size + 2 * w, w), (0, -half_o, size + 2 * w, w),
                (-half_o, 0, w, size), (half_o, 0, w, size))):
            part(box(f"{name} {i}", (sx, sy, t), (cx + dx, cy + dy, z), F, mat, bevel=0.3), 1)

    if direction == "nonet":
        aps = [(-W.PANEL + j * W.PANEL, pic_cy + W.PANEL - k * W.PANEL, NONET_AP)
               for k in range(3) for j in range(3)]
    else:
        aps = [(0.0, pic_cy, APERTURE)]

    part(box("Smoked acrylic", (APERTURE + 40, APERTURE + 40, W.ACR_T),
             (0, pic_cy, z_acr_back + W.ACR_T / 2), F, smoke, bevel=0.4), 1)

    # the perimeter wall between board and mask. Without it the face plate
    # floats 35 mm off the carcass with a void behind its edge, which the
    # first side render showed plainly.
    sp_h = z_mask_back - Z_STEEL_FRONT
    sp_z = (Z_STEEL_FRONT + z_mask_back) / 2
    sp_w = 22.0
    for i, (dx, dy, sx, sy) in enumerate((
            (0, hh - sp_w / 2, BOARD_W, sp_w), (0, -hh + sp_w / 2, BOARD_W, sp_w),
            (-hw + sp_w / 2, 0, sp_w, BOARD_H - 2 * sp_w),
            (hw - sp_w / 2, 0, sp_w, BOARD_H - 2 * sp_w))):
        part(box(f"Surround {i}", (sx, sy, sp_h), (dx, dy, sp_z), F, cloth, bevel=0.6), 2)

    mask = part(box("Front mask", (BOARD_W, BOARD_H, MASK_T),
                    (0, 0, (z_mask_back + z_mask_front) / 2), F, cloth, bevel=0.5), 1)
    for i, (ax, ay, asz) in enumerate(aps):
        part(box(f"Aperture {i}", (asz, asz, MASK_T + 8), (ax, ay, (z_mask_back + z_mask_front) / 2), MCUT), 1)
    part(box("Lip cutout", (BOARD_W + 8, LIP_H, MASK_T + 8), (0, lip_cy, (z_mask_back + z_mask_front) / 2), MCUT), 1)
    m = mask.modifiers.new("Openings", "BOOLEAN")
    m.operation, m.operand_type, m.collection, m.solver = "DIFFERENCE", "COLLECTION", MCUT, "EXACT"
    for i, (ax, ay, asz) in enumerate(aps):
        ring(f"Bezel {i}", ax, ay, asz, 3.0, MASK_T + 0.5, (z_mask_back + z_mask_front) / 2, alu)

    # the alloy band: the one place the object admits it is equipment
    LCUT = collection("Cutters lip")
    LCUT.hide_render = True
    lip = part(box("Alloy lip", (BOARD_W, LIP_H, MASK_T), (0, lip_cy, (z_mask_back + z_mask_front) / 2),
                   F, alu, bevel=0.4), 1)
    part(box("Readout window", WIN + (MASK_T + 8,), (win_c[0], win_c[1], (z_mask_back + z_mask_front) / 2), LCUT), 1)
    part(cylinder("Knob hole", 4.0, MASK_T + 8, (knob_c[0], knob_c[1], (z_mask_back + z_mask_front) / 2), LCUT), 1)
    m = lip.modifiers.new("Openings", "BOOLEAN")
    m.operation, m.operand_type, m.collection, m.solver = "DIFFERENCE", "COLLECTION", LCUT, "EXACT"
    for i, (dx, dy, sx, sy) in enumerate((
            (0, WIN[1] / 2 + 1.5, WIN[0] + 6, 3.0), (0, -WIN[1] / 2 - 1.5, WIN[0] + 6, 3.0),
            (-WIN[0] / 2 - 1.5, 0, 3.0, WIN[1]), (WIN[0] / 2 + 1.5, 0, 3.0, WIN[1]))):
        part(box(f"Window bezel {i}", (sx, sy, MASK_T + 0.6),
                 (win_c[0] + dx, win_c[1] + dy, (z_mask_back + z_mask_front) / 2), F, anod, bevel=0.3), 1)

    # the control: rotate to dim, press to change mode
    part(cylinder("Knob", KNOB_D / 2, KNOB_H, (knob_c[0], knob_c[1], z_mask_front + KNOB_H / 2 - 1),
                  F, alu, verts=64), 1)
    part(box("Knob index", (1.6, KNOB_D / 2 - 3, 0.9),
             (knob_c[0], knob_c[1] + KNOB_D / 4 + 1, z_mask_front + KNOB_H - 1), F, anod), 1)

    if direction == "instrument":
        # the fixings shown, on a grid, because on this one they are ornament
        for gx in range(-2, 3):
            for gy in (-1, 1):
                part(cylinder(f"Fastener {gx}{gy}", FASTENER_D / 2, 1.2,
                              (gx * 130.0, pic_cy + gy * (APERTURE / 2 + 30), z_mask_front - 0.3),
                              F, alu, verts=16), 1)
        for gy in (-1, 1):
            for gx in (-1, 1):
                part(cylinder(f"Fastener s{gx}{gy}", FASTENER_D / 2, 1.2,
                              (gx * (APERTURE / 2 + 30), pic_cy + gy * 130.0, z_mask_front - 0.3),
                              F, alu, verts=16), 1)
        part(box("Legend", (52.0, 3.0, 0.3), (-hw + 60, -hh + 18, z_mask_front - 0.2), F, alu), 1)

    if direction == "vitrine":
        # the well: cloth-lined walls, so the picture sits in a soft box
        t = 6.0
        for i, (dx, dy, sx, sy) in enumerate((
                (0, APERTURE / 2 + t / 2, APERTURE + 2 * t, t), (0, -APERTURE / 2 - t / 2, APERTURE + 2 * t, t),
                (-APERTURE / 2 - t / 2, 0, t, APERTURE), (APERTURE / 2 + t / 2, 0, t, APERTURE))):
            # full height, steel to glass: anything shorter and you see
            # straight past the well into the cavity behind the mask
            part(box(f"Reveal wall {i}", (sx, sy, z_acr_back - Z_STEEL_FRONT),
                     (dx, pic_cy + dy, (Z_STEEL_FRONT + z_acr_back) / 2), F, cloth), 2)

    # ---- the halo: twelve segments, the artwork's own edges ---------------
    H = cols["Halo"]
    cs = halo_colours(face_png)
    # NOT inside the cavity: a closed back would seal the light in. The strip
    # goes on the outer face of the back panel and washes the wall across the
    # gap the pads hold open.
    z_h = Z_PLY_BACK - W.FURRING_D - W.BACK_T - 3.0
    segs = []
    # the side runs centre on the BODY, not the picture. Centring them on
    # pic_cy pushed their top segment 9 mm above the frame, where it showed
    # from the front as a fin.
    for e, (px_, py_, ax_) in enumerate((
            (0.0, -hh + HALO_INSET, "x"), (hw - HALO_INSET, 0.0, "y"),
            (0.0, hh - HALO_INSET, "x"), (-hw + HALO_INSET, 0.0, "y"))):
        span = (BOARD_W if ax_ == "x" else BOARD_H) - 2 * HALO_INSET
        for s in range(HALO_SEGS):
            off = -span / 2 + span / (2 * HALO_SEGS) + s * span / HALO_SEGS
            zl = span / HALO_SEGS
            col = cs[(e * HALO_SEGS + s) % len(cs)]
            for u in range(HALO_SUB):
                sub = -zl / 2 + zl / (2 * HALO_SUB) + u * zl / HALO_SUB
                if ax_ == "x":
                    at, size = (px_ + off + sub, py_, z_h), (zl / HALO_SUB - 3, 9.0, 4.0)
                else:
                    at, size = (px_, py_ + off + sub, z_h), (9.0, zl / HALO_SUB - 3, 4.0)
                segs.append((f"Halo {e}{s}{u}", at, size, col))
    for name, at, size, col in segs:
        em = material(name, (0.02, 0.02, 0.02), 0.5,
                      emit=col if lit else (0, 0, 0), emit_strength=34.0 if lit else 0.0)
        part(box(name, size, at, H, em), 6)

    # ---- the back: rails all round, a vented panel, the electronics -------
    E = cols["Electronics"]
    ECUT = collection("Cutters back")
    ECUT.hide_render = True
    z_frame_back = Z_PLY_BACK - W.FURRING_D
    z_mid = Z_PLY_BACK - W.FURRING_D / 2
    zc_top = Z_PLY_BACK - 1.0
    for i, (sx, sy, w_, h_) in enumerate((
            (0, hh - W.FURRING / 2, BOARD_W, W.FURRING), (0, -hh + W.FURRING / 2, BOARD_W, W.FURRING),
            (-hw + W.FURRING / 2, 0, W.FURRING, BOARD_H - 2 * W.FURRING),
            (hw - W.FURRING / 2, 0, W.FURRING, BOARD_H - 2 * W.FURRING))):
        part(box(f"Rail {i}", (w_, h_, W.FURRING_D), (sx, sy, z_mid), cols["Board"], paint), 7)
    backp = part(box("Back panel", (BOARD_W, BOARD_H, W.BACK_T), (0, 0, z_frame_back - W.BACK_T / 2),
                     cols["Board"], paint, bevel=0.5), 7)
    for i, vy in enumerate((-hh + 120, hh - 120)):
        v = part(box(f"Vent {i}", (W.VENT[0], W.VENT[1], W.BACK_T + 6),
                     (0, vy, z_frame_back - W.BACK_T / 2), ECUT), 7)
        m = backp.modifiers.new(f"Vent {i}", "BOOLEAN")
        m.operation, m.object, m.solver = "DIFFERENCE", v, "EXACT"
    for i, (sx, sy) in enumerate(((-1, 1), (1, 1), (-1, -1), (1, -1))):
        part(box(f"Wall pad {i}", (30, 30, W.WALL_PAD),
                 (sx * (hw - 45), sy * (hh - 45), z_frame_back - W.BACK_T - PAD / 2),
                 cols["Board"], paint), 7)
    y_cl = hh - 60
    z_cl = z_frame_back - W.BACK_T
    part(box("Cleat (frame)", (W.CLEAT_L, W.CLEAT_W - 12, W.CLEAT_T), (0, y_cl + 6, z_cl - W.CLEAT_T / 2),
             cols["Board"], alu, bevel=0.3), 7)
    part(box("Cleat (wall)", (W.CLEAT_L, W.CLEAT_W - 12, W.CLEAT_T), (0, y_cl - 6, z_wall + W.CLEAT_T / 2),
             cols["Board"], alu, bevel=0.3), 8)

    psu_c, bars_c, fuse_c, pi_c = (-20.0, -280.0), (-184.8, 150.0), (-45.0, 130.0), (240.0, 50.0)
    W.borrow("E Power", root, parts, 6, centre=(*psu_c, 0), seat=Z_PLY_BACK,
             keep=lambda n: not any(k in n.lower() for k in ("inlet", "iec", "c14", "mounting tab", "sl22", "ntc")))
    W.borrow("D Controller", root, parts, 6, centre=(*pi_c, 0), seat=Z_PLY_BACK - 3)
    W.borrow("E Bus bars", root, parts, 6, centre=(*bars_c, 0), seat=Z_PLY_BACK)
    W.borrow("U Unresolved fit", root, parts, 6, centre=(*fuse_c, 0), seat=Z_PLY_BACK,
             keep=lambda n: any(k in n.lower() for k in ("fuse", "nilight", "heat", "shrink", "10a", "butt")))
    part(box("C14 inlet module", W.INLET, (-205.0, -hh + W.FURRING / 2, z_mid), E, black, bevel=1.0), 7)
    part(cylinder("SL22 thermistor", W.SL22_D / 2, W.SL22_T, (-140.0, -hh + 40, zc_top - 8), E, black, verts=24), 6)
    part(box("USB microphone", W.MIC, (285.0, -140.0, zc_top - W.MIC[2] / 2), E, black, bevel=1.0), 6)
    part(box("VEML7700 lux sensor", W.LUX, (150.0, hh - 120, z_frame_back - W.BACK_T / 2), E, pcb_dark), 7)
    # the readout's own driver: the bonnet's three ports are full at three
    # panels each, so the tenth panel gets the spare Pico 2 W
    part(box("Pico 2 W (readout)", (51.0, 21.0, 3.9), (rp[0] - 40, rp[1] + 40, zc_top - 4), E, pcb_dark, bevel=0.4), 6)
    part(cylinder("Readout feed hole", 6.0, d_cut, (rp[0], rp[1] + 40, z_cut), CUT), 5)

    # ---- wiring ------------------------------------------------------------
    WI = cols["Wiring"]
    z_gap = Z_STEEL_FRONT + 1.2
    z_in, z_out = Z_STEEL_FRONT + 1.0, Z_PLY_BACK - 2.0
    z_back = zc_top - 18.0
    for r in range(3):
        for c in range(3):
            cx = -half + W.PANEL / 2 + c * W.PANEL
            cy = pic_cy + half - W.PANEL / 2 - r * W.PANEL
            k = r * 3 + c
            fx, fy = fuse_c[0] - 41 + (k % 3) * 41, fuse_c[1] + 35 - (k // 3) * 35
            part(cable(f"Drop {k+1} +", [(bars_c[0] + 50, bars_c[1] + 10, z_back), (fx + 20, fy, z_back),
                                         (cx + 2.5, cy + 3, z_out, "V"), (cx + 2.5, cy + 3, z_in, "V"),
                                         (cx + 3, cy - 30, z_gap), (cx + 3, cy - 50, Z_PANEL_BACK + 3)],
                       1.2, WI, red), 6)
            part(cable(f"Drop {k+1} -", [(bars_c[0] + 50, bars_c[1] - 20, z_back),
                                         (cx - 2.5, cy - 3, z_out, "V"), (cx - 2.5, cy - 3, z_in, "V"),
                                         (cx - 3, cy - 30, z_gap), (cx - 3, cy - 50, Z_PANEL_BACK + 3)],
                       1.2, WI, blk), 6)
        cx = -half + W.PANEL / 2 + W.CHAIN_START_COL * W.PANEL
        cy = pic_cy + half - W.PANEL / 2 - r * W.PANEL
        part(cable(f"Ribbon port {r+1}", [(pi_c[0] - 30, pi_c[1], z_back - 6),
                                          ((pi_c[0] + cx) / 2, (pi_c[1] + cy) / 2, z_back - 8),
                                          (cx + 8, cy - 1.5, z_out, "V"), (cx + 8, cy + 1.5, z_in, "V"),
                                          (cx + 28, cy + 24, z_gap), (cx + 48, cy + 34, Z_PANEL_BACK + 2)],
                   10.15, WI, material("Ribbon", (0.42, 0.42, 0.44), 0.7), flat=True), 6)
    for i in range(3):
        part(cable(f"Feed + {i}", [(psu_c[0] + 100, psu_c[1] + 50 + i * 6, z_back),
                                   (bars_c[0] + 60, bars_c[1] + 6, z_back)], 1.7, WI, red), 6)
        part(cable(f"Feed - {i}", [(psu_c[0] + 100, psu_c[1] + 30 + i * 6, z_back),
                                   (bars_c[0] + 60, bars_c[1] - 26, z_back)], 1.7, WI, blk), 6)
    part(cable("Readout feed", [(bars_c[0] + 50, bars_c[1] - 40, z_back), (rp[0] - 40, rp[1] + 46, zc_top - 6),
                                (rp[0], rp[1] + 40, z_out, "V"), (rp[0], rp[1] + 40, z_in, "V"),
                                (rp[0], rp[1] + 20, Z_PANEL_BACK + 3)], 1.1, WI, red), 6)
    part(cable("Knob lead", [(knob_c[0], knob_c[1], z_mask_back - 6), (knob_c[0], knob_c[1] + 30, Z_STEEL_FRONT + 4),
                             (pi_c[0] - 60, pi_c[1] - 80, z_back)], 1.0, WI, blk), 6)

    # ---- studio -----------------------------------------------------------
    S = cols["Studio"]
    plaster = material("Plaster", (0.50, 0.47, 0.44), 0.92)
    floor_m = material("Studio floor", (0.035, 0.034, 0.032), 0.30)
    y_wall = 2 * mm(-z_wall)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    wallp = bpy.context.active_object
    wallp.name = "Room wall"
    wallp.scale = (7.0, 4.5, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    wallp.rotation_euler = (math.pi / 2, 0, 0)
    wallp.location = (0, y_wall + 0.002, 1.7)
    wallp.data.materials.append(plaster)
    link(wallp, S)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    floor = bpy.context.active_object
    floor.name = "Floor"
    floor.scale = (9.0, 9.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    floor.location = (0, -2.5, 0)
    floor.data.materials.append(floor_m)
    link(floor, S)

    world = bpy.data.worlds.new("World")
    sc.world = world
    if hasattr(world, "use_nodes"):
        world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.012, 0.012, 0.013, 1)

    def area(name, loc, target, power, size, color=(1, 1, 1), size_y=None):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy, ld.size, ld.color = power, size, color
        if size_y:
            ld.shape, ld.size_y = "RECTANGLE", size_y
        lo = bpy.data.objects.new(name, ld)
        lo.location = loc
        lo.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        sc.collection.objects.link(lo)
        return lo

    lights = {
        # cloth needs a raking light to show its weave, and smoked acrylic
        # mirrors anything big and frontal, so the key is small, high and
        # off to the side where its reflection misses the sheet
        "key": area("Key", (-2.4, -1.2, 3.3), (-0.25, 0.15, 1.35), 260, 0.8, (1.0, 0.96, 0.90)),
        "fill": area("Fill", (2.5, -1.3, 2.9), (0.35, 0.10, 1.30), 110, 1.5, (0.90, 0.94, 1.0)),
        "rim": area("Rim", (1.8, 0.7, 2.9), (0.20, 0.0, 1.55), 190, 0.22, (1.0, 0.98, 0.95), size_y=2.0),
        "back": area("Back light", (0.8, 1.9, 2.4), (0, 0.1, 1.45), 150, 1.6),
    }
    lights["back"].hide_render = True

    cam_data = bpy.data.cameras.new("Camera")
    cam_data.lens, cam_data.sensor_width = 50, 36
    cam = bpy.data.objects.new("Camera", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    geom = dict(y_wall=y_wall, z_wall=z_wall, y_face=mm(-z_wall) - mm(z_mask_front),
                lip_z=mm(W.WALL_H) + mm(lip_cy), knob=knob_c, win=win_c, pic_cy=pic_cy,
                z_mask_front=z_mask_front)
    return sc, cam, parts, lights, wallp, floor, geom


# ===================================================================== main

def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="design/renders")
    ap.add_argument("--face", default="")
    ap.add_argument("--samples", type=int, default=180)
    ap.add_argument("--direction", default="console",
                    choices=("console", "vitrine", "instrument", "nonet"))
    ap.add_argument("--palette", default="charcoal",
                    choices=("charcoal", "oatmeal", "oxblood", "forest", "ink"))
    ap.add_argument("--views", default="hero,front,side,detail,back,off")
    ap.add_argument("--prefix", default="")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    prefix = args.prefix or f"{args.direction}-{args.palette}"
    face = os.path.abspath(args.face) if args.face else ""
    views = args.views.split(",")

    def scene(lit=True):
        return build(args.direction, args.palette, face, lit=lit)

    sc, cam, parts, lights, wallp, floor, g = scene(True)
    W.glare(sc)
    C = (0.0, mm(-g["z_wall"]) - 0.02, mm(W.WALL_H))

    if "hero" in views:
        W.aim(cam, (-1.05, -1.62, 1.66), C, lens=55, fstop=4.0)
        W.render(sc, os.path.join(args.out, f"{prefix}-hero.png"), args.samples)
    if "front" in views:
        W.aim(cam, (0.0, -2.15, mm(W.WALL_H)), C, lens=60)
        W.render(sc, os.path.join(args.out, f"{prefix}-front.png"), args.samples)
    if "side" in views:
        W.aim(cam, (1.85, -0.50, 1.56), (0.0, g["y_face"] + 0.05, mm(W.WALL_H) - 0.01), lens=50, fstop=11.0)
        W.render(sc, os.path.join(args.out, f"{prefix}-side.png"), args.samples)
    if "detail" in views:
        # the alloy band: one knob, one window, and the chamfer running out
        t = (0.0, g["y_face"], g["lip_z"])
        W.aim(cam, (0.02, t[1] - 0.70, t[2] + 0.17), t, lens=45, fstop=5.6, focus=t)
        W.render(sc, os.path.join(args.out, f"{prefix}-detail.png"), args.samples)
    if "back" in views:
        lights["back"].hide_render = False
        W.aim(cam, (0.62, 1.25, 1.80), (0.0, 0.10, 1.46), lens=40)
        W.render(sc, os.path.join(args.out, f"{prefix}-back.png"), args.samples)
        lights["back"].hide_render = True
    blend = os.path.join(args.out, f"{prefix}.blend")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend))

    if "off" in views:
        # the whole point of the cloth and the chamfer: what it is with
        # nothing playing
        sc, cam, parts, lights, wallp, floor, g = scene(False)
        W.glare(sc)
        lights["key"].data.energy = 420
        lights["fill"].data.energy = 190
        W.aim(cam, (-0.72, -1.55, 1.62), (0.0, mm(-g["z_wall"]) - 0.02, mm(W.WALL_H)), lens=55, fstop=4.5)
        W.render(sc, os.path.join(args.out, f"{prefix}-off.png"), args.samples)

    print("direction %s, palette %s" % (args.direction, args.palette))
    print("body %.1f x %.1f mm, picture %.0f, bottom border %.1f, lip %.0f"
          % (BOARD_W, BOARD_H, W.FACE, BOTTOM, LIP_H))
    print("glass %.1f mm over the LEDs%s; halo %d segments sampled from the artwork"
          % (AIR, " plus a %.0f mm well" % RECESS if args.direction == "vitrine" else "",
             4 * HALO_SEGS * HALO_SUB))


if __name__ == "__main__":
    main()
