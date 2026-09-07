"""The Tessera wall, as a Blender model. Second design.

Nine Waveshare P2.5 64x64 panels behind opal and smoked acrylic, held on a
slotted steel plate by their own magnets, in a black walnut shadow box with a
black anodised aluminium reveal, brass splines at the mitres, hidden vents,
and one mains cord. Everything the wall needs lives behind the plate.

Every dimension is a number at the top of this file, in millimetres, with
where it came from beside it. VERIFIED means a datasheet, a drawing, a board
file or a manual said so. LISTING means a retailer's listing said so. TYPICAL
means the number is the usual one for that kind of part and has not been
checked against the part in hand. DESIGN means it is a choice, not a fact.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python design/wall_model.py -- --out design/renders --face design/face192.png
"""
import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

# ================================================================== numbers
# --- the panels -------------------------------------------------------------
TILE_PX = 64
PITCH = 2.5                    # VERIFIED  Waveshare: P2.5
PANEL = 160.0                  # VERIFIED  Waveshare wiki and manual: 160 x 160
PANEL_T = 14.5                 # VERIFIED  Waveshare manual, drawing 3.1
PANEL_G = 100.0                # VERIFIED  manual: 3.53 oz
MAG_FOOT_H = 3.0               # TYPICAL   the manual lists four magnetic feet per
                               #           panel; their height is not stated. They
                               #           are placed on four of the drawing's M3 points
COLS = ROWS = 3
FACE = PANEL * COLS            # 480

# --- the glazing ------------------------------------------------------------
GAP_AIR = 2.0                  # DESIGN    LED face to the opal sheet
OPAL_T = 3.0                   # DESIGN    3 mm opal acrylic (PARTS.md)
SMOKE_T = 3.0                  # DESIGN    3 mm smoked ND acrylic (PARTS.md)
REVEAL_T = 3.0                 # DESIGN    black anodised aluminium liner, 3 mm
REVEAL_RETURN = 6.0            # DESIGN    how far the liner runs back
WINDOW = FACE + 4              # DESIGN    484: the liner shows 2 mm past the LEDs
ACRYLIC = WINDOW + 8           # DESIGN    492: the sheets sit 4 mm under the liner
SHADOW = 5.0                   # DESIGN    the wood stands 5 mm proud of the glass

# --- the frame --------------------------------------------------------------
FRAME_W = 16.0                 # DESIGN    black walnut, face width
FRAME_D = None                 # computed below
SPLINE_T, SPLINE_W = 1.5, 12.0 # DESIGN    brass splines through each mitre
BACK_T = 3.0                   # DESIGN    black anodised aluminium back
PLENUM = 12.0                  # DESIGN    back panel inset: the vent path
VENT_SLOT = (3.0, 14.0)        # DESIGN    slot width and length, milled in the rails

# --- the carcass ------------------------------------------------------------
STEEL_T = 1.5                  # DESIGN    galvanised steel mount plate
STEEL = FACE + 16              # DESIGN    496 square, inside the frame
CAVITY = 40.0                  # DESIGN    behind the plate. Pi + riser + bonnet
                               #           stacks to ~36, PSU is 30 (see below)

# --- the electronics: all from datasheets and board files -----------------
PSU = (215.0, 115.0, 30.0)     # VERIFIED  LRS-350-5 datasheet, 0.76 kg, case 207A
PSU_TERMINALS = ("L", "N", "FG", "-V", "-V", "-V", "+V", "+V", "+V")
                               # VERIFIED  datasheet pin assignment 1..9
PI = (85.0, 56.0, 1.6)         # VERIFIED  Pi 5 mechanical drawing
PI_HOLES = ((3.5, 3.5), (61.5, 3.5), (3.5, 52.5), (61.5, 52.5))
                               # VERIFIED  drawing: 58 x 49 on 3.5 insets, dia 2.7
COOLER = (63.5, 42.5, 13.7)    # VERIFIED  Active Cooler product brief
RISER_PIN = 12.0               # LISTING   Frienda stacking header: 12 mm pins
RISER_BODY = 8.5               # TYPICAL   2x20 female header body height
BONNET = (65.0, 30.7, 1.6)     # VERIFIED  Eagle board file, layer 20 outline
BONNET_IDC = ((32.131, 4.572), (14.351, 17.3355), (50.8, 17.272))
                               # VERIFIED  board file: three 2x8 shrouded headers
BONNET_QT = (13.97, 3.302)     # VERIFIED  board file: JST SH 4 (STEMMA QT)
IDC = (20.3, 8.9, 9.0)         # TYPICAL   2x8 shrouded box header outline
BUSBAR = (137.2, 22.9, 38.1)   # LISTING   RVBOATPAT dimension image: 5.4 x 0.9 x 1.5 in,
                               #           12 x M4 in two rows at 0.4 in, one 1/4 in stud
FUSE_HOLDER = (36.0, 14.0, 14.0)   # TYPICAL  NI-FH01 body; the listing gives only
                               #           the fuse (19.1 x 18.5 x 5.1) and 12 in leads
INLET = (50.0, 30.0, 30.0)     # LISTING   Antrader: approx 5 x 3 x 3 cm, holes 67 apart
INLET_CUTOUT = (47.0, 27.5)    # TYPICAL   this family of C14 modules
SL22_D, SL22_T = 22.0, 5.0     # VERIFIED  Ametherm datasheet: 22 max dia, 5 max thick
MIC = (22.2, 18.3, 7.0)        # VERIFIED  Adafruit 3367
LUX = (25.5, 17.7, 4.6)        # VERIFIED  Adafruit 4162
CLEAT_L = 304.8                # LISTING   OOK 533208 dimension image: 12 in
CLEAT_W, CLEAT_T = 38.1, 2.0   # LISTING   1.5 in tall; sticks out 1/8 in from the wall
PANEL_SHELL = 159.8            # VERIFIED  Waveshare P2_5 64x64 DWG (official GitHub)
SHELL_D = 12.0                 # VERIFIED  same drawing: rear shell depth
PANEL_M3 = ((-45, -73), (45, -73), (-73, -45), (73, -45),
            (-73, 45), (73, 45), (-45, 73), (45, 73))
                               # VERIFIED  same drawing: eight M3 points from centre
WALL_GAP = 16.0                # DESIGN    spacers hold the back off the wall so the
                               #           rear vents breathe (taken from the atelier study)
VENT = (340.0, 22.0)           # DESIGN    two guarded openings in the back panel
ATELIER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "atelier-v2", "Tessera-Atelier.blend")

# --- depth bookkeeping, from the LED face (z = 0) back (negative z) ---------
Z_PANEL_BACK = -PANEL_T
Z_STEEL_FRONT = Z_PANEL_BACK - MAG_FOOT_H
Z_STEEL_BACK = Z_STEEL_FRONT - STEEL_T
Z_BACK_FRONT = Z_STEEL_BACK - CAVITY
Z_BACK = Z_BACK_FRONT - BACK_T
Z_REAR = Z_BACK - PLENUM                       # the frame's rear edge
Z_GLASS = GAP_AIR + OPAL_T + SMOKE_T           # front face of the smoked sheet
Z_FRONT = Z_GLASS + SHADOW                     # the frame's front face
FRAME_D = Z_FRONT - Z_REAR
OUTER = WINDOW + 2 * (REVEAL_T + FRAME_W)      # 522

WALL_H = 1500.0

# ================================================================== helpers

def mm(v):
    return v / 1000.0


def clean():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "METRIC"
    sc.unit_settings.length_unit = "MILLIMETERS"
    return sc


def collection(name):
    col = bpy.data.collections.new(name)
    bpy.context.scene.collection.children.link(col)
    return col


def link(obj, col):
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    col.objects.link(obj)
    return obj


def principled(name):
    m = bpy.data.materials.new(name)
    if hasattr(m, "use_nodes"):
        m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    if bsdf is None:
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        nt.links.new(bsdf.outputs[0], nt.nodes.new("ShaderNodeOutputMaterial").inputs[0])
    return m, nt, bsdf


def material(name, base=(0.5, 0.5, 0.5), rough=0.5, metal=0.0, transmission=0.0,
             ior=1.45, coat=0.0, emit=None, emit_strength=0.0):
    m = bpy.data.materials.get(name)
    if m:
        return m
    m, nt, b = principled(name)
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    b.inputs["IOR"].default_value = ior
    if "Transmission Weight" in b.inputs:
        b.inputs["Transmission Weight"].default_value = transmission
    if "Coat Weight" in b.inputs:
        b.inputs["Coat Weight"].default_value = coat
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*emit, 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    return m


def box(name, size, at, col, mat=None, bevel=0.0, rot=(0, 0, 0)):
    """A cuboid, size and centre in mm. Scale is applied at the origin, then
    the object is moved: applying after moving bakes the position into the
    mesh and every origin lands at zero."""
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    o = bpy.context.active_object
    o.name = name
    o.scale = (mm(size[0]), mm(size[1]), mm(size[2]))
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    o.location = (mm(at[0]), mm(at[1]), mm(at[2]))
    o.rotation_euler = rot
    if mat:
        o.data.materials.append(mat)
    if bevel:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = mm(bevel)
        b.segments = 4
        b.limit_method = "ANGLE"
    link(o, col)
    return o


def cylinder(name, r, h, at, col, mat=None, axis="Z", verts=32):
    bpy.ops.mesh.primitive_cylinder_add(radius=mm(r), depth=mm(h), vertices=verts)
    o = bpy.context.active_object
    o.name = name
    o.location = (mm(at[0]), mm(at[1]), mm(at[2]))
    if axis == "X":
        o.rotation_euler = (0, math.pi / 2, 0)
    elif axis == "Y":
        o.rotation_euler = (math.pi / 2, 0, 0)
    if mat:
        o.data.materials.append(mat)
    link(o, col)
    return o


def rail(name, length, width, depth, at, rot_z, col, mat, taper=0.0):
    """A mitred rail: the inner edge is shorter by the width at each end.

    `taper` pulls the outer face in at the back, so the box narrows toward
    the wall and reads thinner from the side than it is. The study's
    sculpted shell did this in cast aluminium; a walnut rail does it with
    one pass on a table saw."""
    o = box(name, (length, width, depth), at, col, mat, bevel=0.8)
    half_l, w = mm(length) / 2, mm(width)
    for v in o.data.vertices:
        if v.co.y < 0:
            v.co.x = math.copysign(half_l - w, v.co.x)
        elif v.co.z < 0 and taper:
            v.co.y -= mm(taper)
    o.rotation_euler = (0, 0, rot_z)
    return o


def uv_square(obj, u0, v0, u1, v1):
    me = obj.data
    uv = me.uv_layers.new(name="UVMap") if not me.uv_layers else me.uv_layers[0]
    corners = {(-1, -1): (u0, v0), (1, -1): (u1, v0), (1, 1): (u1, v1), (-1, 1): (u0, v1)}
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            uv.data[li].uv = corners[(1 if co.x > 0 else -1, 1 if co.y > 0 else -1)]


def cable(name, points, radius, col, mat, flat=False):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = mm(radius)
    cu.bevel_resolution = 4
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(points) - 1)
    for bp, p in zip(sp.bezier_points, points):
        bp.co = Vector((mm(p[0]), mm(p[1]), mm(p[2])))
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    o = bpy.data.objects.new(name, cu)
    if flat:
        o.scale = (1, 1, 0.22)
    cu.materials.append(mat)
    link(o, col)
    return o


# ================================================================ materials

def led_material(face_png):
    """One lit disc per LED, the picture sampled pixel for pixel."""
    m, nt, bsdf = principled("LED face")
    bsdf.inputs["Base Color"].default_value = (0.012, 0.012, 0.012, 1)
    bsdf.inputs["Roughness"].default_value = 0.45
    tex = nt.nodes.new("ShaderNodeTexCoord")
    img = nt.nodes.new("ShaderNodeTexImage")
    img.interpolation = "Closest"
    if face_png and os.path.exists(face_png):
        img.image = bpy.data.images.load(face_png)
    nt.links.new(tex.outputs["UV"], img.inputs["Vector"])
    scale = nt.nodes.new("ShaderNodeVectorMath")
    scale.operation = "SCALE"
    scale.inputs["Scale"].default_value = TILE_PX * COLS
    nt.links.new(tex.outputs["UV"], scale.inputs[0])
    frac = nt.nodes.new("ShaderNodeVectorMath")
    frac.operation = "FRACTION"
    nt.links.new(scale.outputs[0], frac.inputs[0])
    centre = nt.nodes.new("ShaderNodeVectorMath")
    centre.operation = "SUBTRACT"
    centre.inputs[1].default_value = (0.5, 0.5, 0.0)
    nt.links.new(frac.outputs[0], centre.inputs[0])
    length = nt.nodes.new("ShaderNodeVectorMath")
    length.operation = "LENGTH"
    nt.links.new(centre.outputs[0], length.inputs[0])
    disc = nt.nodes.new("ShaderNodeMath")
    disc.operation = "LESS_THAN"
    disc.inputs[1].default_value = 0.36
    nt.links.new(length.outputs["Value"], disc.inputs[0])
    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(img.outputs["Color"], mul.inputs[6])
    grey = nt.nodes.new("ShaderNodeCombineColor")
    for k in range(3):
        nt.links.new(disc.outputs[0], grey.inputs[k])
    nt.links.new(grey.outputs[0], mul.inputs[7])
    nt.links.new(mul.outputs[2], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 16.0
    return m


def walnut_material():
    """Black walnut, oiled. Stretched noise, not bands: real grain is streaks
    of three or four tones that wander, and a wave texture reads as fluting.
    Low specular, because a dark wood under a softbox goes milky otherwise."""
    m, nt, bsdf = principled("Black walnut")
    bsdf.inputs["Roughness"].default_value = 0.52
    for name, val in (("Specular IOR Level", 0.28), ("Coat Weight", 0.0)):
        if name in bsdf.inputs:
            bsdf.inputs[name].default_value = val
    tex = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (0.7, 26.0, 5.0)     # grain along x
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
    cr.elements[0].color = (0.014, 0.008, 0.005, 1)
    cr.elements[1].position = 0.70
    cr.elements[1].color = (0.060, 0.032, 0.018, 1)
    mid = cr.elements.new(0.50)
    mid.color = (0.034, 0.018, 0.011, 1)
    nt.links.new(grain.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.025
    nt.links.new(fine.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def brushed_material(name, base, rough=0.32, aniso=0.6):
    m, nt, bsdf = principled(name)
    bsdf.inputs["Base Color"].default_value = (*base, 1)
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = rough
    if "Anisotropic" in bsdf.inputs:
        bsdf.inputs["Anisotropic"].default_value = aniso
    return m


# ============================================================ borrowed CAD

def borrow(name, root, parts, layer, centre=None, keep=None):
    """Append a collection from the atelier study and stand it in this model.

    The study's Pi 5 is Raspberry Pi's own STEP and its bonnet is Adafruit's
    own 3MF, which is better than any box drawn from a datasheet. Its scene
    puts the LED face at y = -95 with the viewer at -y and up along z; this
    model has the face at local z = 0 with depth along -z and up along y, so
    the borrowed objects hang off one empty that turns their frame into ours.
    `centre` then moves the whole group so its middle lands where this design
    wants it, in local mm. `keep` filters by name.
    """
    if not os.path.exists(ATELIER):
        print("atelier blend missing, skipping", name)
        return []
    before = set(bpy.data.objects)
    bpy.ops.wm.append(directory=ATELIER + "/Collection/", filename=name, link=False)
    col = bpy.data.collections.get(name)
    objs = [o for o in col.all_objects if o not in before or True]
    pivot = bpy.data.objects.new(f"Atelier {name}", None)
    bpy.context.scene.collection.objects.link(pivot)
    pivot.parent = root
    pivot.rotation_euler = (-math.pi / 2, 0, 0)
    pivot.location = (0, 0, mm(-95))
    kept = []
    for o in list(objs):
        if keep and not keep(o.name):
            bpy.data.objects.remove(o, do_unlink=True)
            continue
        if o.parent is None or o.parent not in objs:
            o.parent = pivot
            o.matrix_parent_inverse.identity()
        kept.append(o)
    bpy.context.view_layer.update()
    if centre is not None and kept:
        inv = root.matrix_world.inverted()
        pts = [inv @ (o.matrix_world @ Vector(c)) for o in kept if o.type == "MESH" for c in o.bound_box]
        if pts:
            mid = Vector((sum(p.x for p in pts) / len(pts), sum(p.y for p in pts) / len(pts), sum(p.z for p in pts) / len(pts)))
            lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
            hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
            mid = (lo + hi) / 2
            want = Vector((mm(centre[0]), mm(centre[1]), mm(centre[2])))
            # move the pivot in root-local terms
            pivot.location = Vector(pivot.location) + (want - mid)
            bpy.context.view_layer.update()
            print("borrowed %-22s %4d objects, %.0f x %.0f x %.0f mm, placed" % (
                name, len(kept), (hi.x - lo.x) * 1000, (hi.y - lo.y) * 1000, (hi.z - lo.z) * 1000))
    for o in kept:
        parts[o.name] = (o, layer)
    return kept


# ==================================================================== build

def build(face_png):
    sc = clean()
    root = bpy.data.objects.new("Wall", None)
    sc.collection.objects.link(root)
    root.rotation_euler = (math.pi / 2, 0, 0)        # face toward -Y, up is +Z
    root.location = (0, mm(-Z_REAR), mm(WALL_H))

    cols = {n: collection(n) for n in ("Panels", "Glazing", "Frame", "Carcass", "Electronics", "Wiring", "Studio")}
    parts = {}

    black = material("Panel plastic", (0.02, 0.02, 0.02), 0.55)
    pcb_dark = material("PCB dark", (0.012, 0.03, 0.02), 0.5)
    pcb_pi = material("PCB Pi green", (0.02, 0.09, 0.035), 0.45)
    ic = material("IC", (0.03, 0.03, 0.03), 0.35)
    alu = brushed_material("Aluminium", (0.80, 0.80, 0.82), 0.30)
    anod = brushed_material("Black anodised", (0.045, 0.045, 0.048), 0.36, 0.5)
    steel = brushed_material("Galvanised steel", (0.62, 0.63, 0.64), 0.42, 0.3)
    brass = brushed_material("Brass", (0.86, 0.66, 0.30), 0.26)
    tin = brushed_material("Tinned copper", (0.75, 0.76, 0.74), 0.35)
    nylon = material("Nylon", (0.90, 0.88, 0.82), 0.7)
    red = material("Red lead", (0.55, 0.03, 0.02), 0.5)
    blk = material("Black lead", (0.012, 0.012, 0.012), 0.5)
    ribbon = material("Ribbon", (0.30, 0.30, 0.33), 0.7)
    white = material("White plastic", (0.85, 0.85, 0.82), 0.5)
    opal = material("Opal acrylic", (0.96, 0.96, 0.96), 0.08, transmission=1.0, ior=1.0)
    smoke = material("Smoked acrylic", (0.30, 0.30, 0.32), 0.02, transmission=1.0, ior=1.49, coat=0.0)
    walnut = walnut_material()
    led = led_material(face_png)
    plaster = material("Plaster", (0.56, 0.50, 0.43), 0.9)
    studio = material("Studio", (0.045, 0.043, 0.040), 0.55)
    floor_m = material("Studio floor", (0.035, 0.034, 0.032), 0.28)

    def part(o, layer):
        o.parent = root
        parts[o.name] = (o, layer)
        return o

    half = FACE / 2

    # ---- nine panels ---------------------------------------------------
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            n = r * COLS + c + 1
            # the rear shell comes from the drawing, below; here only the PCB
            part(box(f"Panel {n} PCB", (PANEL - 0.4, PANEL - 0.4, 1.6),
                     (cx, cy, -0.8), cols["Panels"], pcb_dark), 3)
            bpy.ops.mesh.primitive_plane_add(size=1.0)
            face = bpy.context.active_object
            face.name = f"Panel {n} LEDs"
            face.scale = (mm(PANEL), mm(PANEL), 1)
            bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
            face.location = (mm(cx), mm(cy), mm(0.15))
            uv_square(face, c / COLS, (ROWS - 1 - r) / ROWS, (c + 1) / COLS, (ROWS - r) / ROWS)
            face.data.materials.append(led)
            link(face, cols["Panels"])
            part(face, 3)
            # The back, REPRESENTATIVE: the manual documents two HUB75 headers,
            # a VH4 power header and four magnetic feet, not where they sit.
            zb = -PANEL_T + 5.5
            for k, dx in enumerate((-48, 48)):
                part(box(f"Panel {n} HUB75 {'in' if k == 0 else 'out'}", IDC,
                         (cx + dx, cy + 44, zb), cols["Panels"], black), 3)
            part(box(f"Panel {n} VH4", (12.0, 9.0, 8.0), (cx, cy - 58, zb), cols["Panels"], white), 3)
            for i in range(4):
                for j in range(2):
                    part(box(f"Panel {n} IC {i}{j}", (7.0, 5.0, 1.6),
                             (cx - 45 + i * 30, cy - 10 + j * 22, -PANEL_T + 1.6), cols["Panels"], ic), 3)
            # magnetic feet on four of the drawing's eight M3 points
            for k, (mx, my) in enumerate((PANEL_M3[0], PANEL_M3[1], PANEL_M3[6], PANEL_M3[7])):
                part(cylinder(f"Panel {n} magnet {k}", 5.0, MAG_FOOT_H,
                              (cx + mx, cy + my, -PANEL_T - MAG_FOOT_H / 2),
                              cols["Panels"], tin, verts=24), 3)
    # the ribbed rear shells, 159.8 square and 12 deep, from the official DWG
    borrow("P Panels", root, parts, 3, keep=lambda n: "PCB face" not in n)

    # ---- glazing and the reveal ------------------------------------------
    part(box("Opal acrylic", (ACRYLIC, ACRYLIC, OPAL_T), (0, 0, GAP_AIR + OPAL_T / 2),
             cols["Glazing"], opal), 2)
    part(box("Smoked acrylic", (ACRYLIC, ACRYLIC, SMOKE_T),
             (0, 0, GAP_AIR + OPAL_T + SMOKE_T / 2), cols["Glazing"], smoke), 1)
    # the liner: a face ring in front of the glass edge, and a return that
    # runs back past the sheets to the panel frames
    rz = Z_GLASS + REVEAL_T / 2
    w_out = WINDOW + 2 * REVEAL_T
    for name, size, at in (("Reveal top", (w_out, REVEAL_T, REVEAL_T), (0, WINDOW / 2 + REVEAL_T / 2, rz)),
                           ("Reveal bottom", (w_out, REVEAL_T, REVEAL_T), (0, -WINDOW / 2 - REVEAL_T / 2, rz)),
                           ("Reveal left", (REVEAL_T, WINDOW, REVEAL_T), (-WINDOW / 2 - REVEAL_T / 2, 0, rz)),
                           ("Reveal right", (REVEAL_T, WINDOW, REVEAL_T), (WINDOW / 2 + REVEAL_T / 2, 0, rz))):
        part(box(name, size, at, cols["Glazing"], anod), 1)
    ret_z = (Z_GLASS - REVEAL_RETURN - 8) / 2
    ret_d = Z_GLASS + REVEAL_RETURN
    for name, size, at in (("Return top", (ACRYLIC + 2 * REVEAL_T, REVEAL_T, ret_d), (0, ACRYLIC / 2 + REVEAL_T / 2, ret_z)),
                           ("Return bottom", (ACRYLIC + 2 * REVEAL_T, REVEAL_T, ret_d), (0, -ACRYLIC / 2 - REVEAL_T / 2, ret_z)),
                           ("Return left", (REVEAL_T, ACRYLIC, ret_d), (-ACRYLIC / 2 - REVEAL_T / 2, 0, ret_z)),
                           ("Return right", (REVEAL_T, ACRYLIC, ret_d), (ACRYLIC / 2 + REVEAL_T / 2, 0, ret_z))):
        part(box(name, size, at, cols["Glazing"], anod), 1)

    # ---- the frame -------------------------------------------------------
    zc = (Z_FRONT + Z_REAR) / 2
    off = OUTER / 2 - FRAME_W / 2
    for name, at, rot in (("Rail top", (0, off, zc), 0), ("Rail bottom", (0, -off, zc), math.pi),
                          ("Rail left", (-off, 0, zc), math.pi / 2), ("Rail right", (off, 0, zc), -math.pi / 2)):
        part(rail(name, OUTER, FRAME_W, FRAME_D, at, rot, cols["Frame"], walnut, taper=6.0), 0)
    # brass splines through the mitres: a keyed mitre reads as a thin brass
    # line at constant depth across both outer faces of each corner, twice
    for sx in (-1, 1):
        for sy in (-1, 1):
            for k, zpos in enumerate((Z_FRONT - 16, Z_REAR + 16)):
                part(box(f"Spline {sx}{sy}{k} side", (0.6, SPLINE_W, SPLINE_T),
                         (sx * (OUTER / 2 + 0.1), sy * (OUTER / 2 - SPLINE_W / 2 - 1.5), zpos),
                         cols["Frame"], brass), 0)
                part(box(f"Spline {sx}{sy}{k} top", (SPLINE_W, 0.6, SPLINE_T),
                         (sx * (OUTER / 2 - SPLINE_W / 2 - 1.5), sy * (OUTER / 2 + 0.1), zpos),
                         cols["Frame"], brass), 0)
    # the mark: the app's 7x7 lattice in brass, one tile lit, bottom rail
    mark_y = -(OUTER / 2 - FRAME_W / 2)
    for i in range(7):
        for j in range(7):
            lit = (i, j) == (4, 2)
            s = 1.9 if lit else 1.25
            part(box(f"Mark {i}{j}", (s, s, 0.5), ((i - 3) * 2.4, mark_y + (j - 3) * 2.4, Z_FRONT + 0.25),
                     cols["Frame"], brass), 0)
    # the sensor eye and the microphone pinholes, in the rails, 1.2 mm
    part(cylinder("Lux eye", 1.2, FRAME_W + 1, (OUTER / 2 - 34, OUTER / 2 - FRAME_W / 2, Z_FRONT - 8),
                  cols["Frame"], black, axis="Y", verts=16), 0)
    for i in range(5):
        part(cylinder(f"Mic pinhole {i}", 0.7, FRAME_W + 1,
                      (-OUTER / 2 + 40 + i * 3.2, -(OUTER / 2 - FRAME_W / 2), Z_REAR + 30),
                      cols["Frame"], black, axis="Y", verts=12), 0)

    # ---- carcass -----------------------------------------------------------
    plate = part(box("Steel mount plate", (STEEL, STEEL, STEEL_T), (0, 0, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2),
                     cols["Carcass"], steel), 5)
    # cable slots behind every panel's connector zone, generous on purpose:
    # the connector positions are representative, the slots need not be
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            part(box(f"Slot {r}{c} data", (110, 22, STEEL_T + 0.6), (cx, cy + 44, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2),
                     cols["Carcass"], black), 5)
            part(box(f"Slot {r}{c} power", (30, 18, STEEL_T + 0.6), (cx, cy - 58, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2),
                     cols["Carcass"], black), 5)
    part(box("Back panel", (OUTER - 2 * FRAME_W - 1, OUTER - 2 * FRAME_W - 1, BACK_T),
             (0, 0, (Z_BACK_FRONT + Z_BACK) / 2), cols["Carcass"], anod), 7)
    # two guarded vent openings, low and high, straight through the back;
    # the supply's fan pulls in below and the warm air leaves above
    for sy, label in ((-1, "intake"), (1, "outlet")):
        part(box(f"Vent {label}", (VENT[0], VENT[1], BACK_T + 0.6), (0, sy * 200, (Z_BACK_FRONT + Z_BACK) / 2),
                 cols["Carcass"], black), 7)
        for i in range(-33, 34):
            part(box(f"Vent {label} bar {i + 33}", (1.4, VENT[1], BACK_T + 0.8), (i * 5.0, sy * 200, (Z_BACK_FRONT + Z_BACK) / 2),
                     cols["Carcass"], anod), 7)
    # the back stands off the wall by WALL_GAP on four pads, so the vents work
    for i, (sx, sy) in enumerate(((-1, 1), (1, 1), (-1, -1), (1, -1))):
        part(box(f"Wall pad {i}", (30, 30, WALL_GAP), (sx * 200, sy * 215, Z_REAR - WALL_GAP / 2),
                 cols["Carcass"], black, bevel=1.0), 8)
    for i, (sx, sy) in enumerate(((-1, -1), (1, -1), (-1, 1), (1, 1), (0, -1), (0, 1), (-1, 0), (1, 0))):
        part(cylinder(f"Back screw {i}", 2.6, 1.0, (sx * (OUTER / 2 - FRAME_W - 12), sy * (OUTER / 2 - FRAME_W - 12), Z_BACK - 0.5),
                      cols["Carcass"], anod, verts=20), 7)
    # the cleat pair, wall half and frame half, near the top of the back
    cleat_y = OUTER / 2 - FRAME_W - 40
    c1 = part(box("Cleat (frame)", (CLEAT_L, CLEAT_W, CLEAT_T), (0, cleat_y, Z_BACK - CLEAT_T / 2 - 1),
                  cols["Carcass"], alu, bevel=0.4), 7)
    c1.rotation_euler = (math.radians(30), 0, 0)
    c2 = part(box("Cleat (wall)", (CLEAT_L, CLEAT_W, CLEAT_T), (0, cleat_y - 20, Z_REAR - CLEAT_T / 2),
                  cols["Carcass"], alu, bevel=0.4), 8)
    c2.rotation_euler = (math.radians(30), 0, 0)
    part(box("Badge", (30, 11, 0.8), (OUTER / 2 - FRAME_W - 40, -(OUTER / 2 - FRAME_W - 30), Z_BACK - 0.4),
             cols["Carcass"], brass), 7)

    # ---- electronics, in the cavity behind the plate ----------------------
    zc_top = Z_STEEL_BACK - 1.0                       # things sit against the plate
    E = cols["Electronics"]
    # the supply, with its fan cutout and label, from the study's reconstruction
    psu_at = (-30, -half + PSU[1] / 2 + 6, zc_top - PSU[2] / 2)
    borrow("E Power", root, parts, 6, centre=psu_at,
           keep=lambda n: "inlet" not in n.lower() and "iec" not in n.lower())
    # Pi 5 and Triple Bonnet: the manufacturers' own CAD, stacked on the riser
    pi_at = (-half + PI[0] / 2 + 24, half - PI[1] / 2 - 30, zc_top - 17)
    borrow("D Controller", root, parts, 6, centre=pi_at)
    for i in range(4):
        part(cylinder(f"Pi standoff {i}", 2.5, 3.0, (pi_at[0] - PI[0] / 2 + PI_HOLES[i][0], pi_at[1] - PI[1] / 2 + PI_HOLES[i][1], zc_top - 1.5), E, nylon, verts=16), 6)
    # the bus bars, 5.4 in each, from the seller's dimension image
    bus_plus = (half - 40, 110)
    bus_minus = (half - 40, 20)
    borrow("E Bus bars", root, parts, 6, centre=(half - 40, 65, zc_top - 20),
           keep=lambda n: "cover" not in n.lower() and "cap" not in n.lower())
    # nine labelled fuse holders and their heat-shrink joints
    fuse_c = (30, 140, zc_top - 8)
    borrow("U Unresolved fit", root, parts, 6, centre=fuse_c,
           keep=lambda n: any(k in n.lower() for k in ("fuse", "nilight", "heat", "shrink", "10a", "butt")))
    bx0, by0 = pi_at[0] - 32.5, pi_at[1] - 12
    bonnet_z = pi_at[2] - 16
    # inlet module through the bottom rail, thermistor beside it, mic, lux
    inlet_at = (half - 90, -OUTER / 2 + FRAME_W / 2, Z_REAR + PLENUM + INLET[2] / 2 + 2)
    part(box("C14 inlet module", (INLET[0], INLET[1], INLET[2]), (inlet_at[0], inlet_at[1] + 8, inlet_at[2]), E, black, rot=(math.pi / 2, 0, 0)), 0)
    part(box("Inlet face", (INLET_CUTOUT[0], 1.0, INLET_CUTOUT[1]), (inlet_at[0], -OUTER / 2 - 0.4, inlet_at[2]), E, black), 0)
    part(box("Inlet rocker", (13, 1.2, 19), (inlet_at[0] + 15, -OUTER / 2 - 0.9, inlet_at[2]), E, black), 0)
    part(cylinder("SL22 thermistor", SL22_D / 2, SL22_T, (half - 150, -half + 20, Z_BACK_FRONT + 12), E, black, axis="Y", verts=24), 6)
    part(box("USB microphone", MIC, (-OUTER / 2 + 46, -half + 12, Z_REAR + 30), E, black, bevel=1.0), 6)
    part(box("VEML7700 lux sensor", LUX, (OUTER / 2 - 34, half - 8, Z_FRONT - 12), E, pcb_dark), 0)

    # ---- wiring, suggested but where it would really run -------------------
    W = cols["Wiring"]
    zl = zc_top - 6
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            k = r * COLS + c
            fat = (fuse_c[0] - 41 + (k % 3) * 41, fuse_c[1] + 35 - (k // 3) * 35)
            part(cable(f"Drop {k + 1} +", [(bus_plus[0] - 60 + (k % 6) * 10, bus_plus[1] + 6, zl), (fat[0] + 22, fat[1], zl - 2),
                                            (fat[0] - 22, fat[1], zl - 2), (cx + 6, cy - 58, Z_PANEL_BACK - 6)], 1.3, W, red), 6)
            part(cable(f"Drop {k + 1} -", [(bus_minus[0] - 60 + (k % 6) * 10, bus_minus[1] - 6, zl), ((bus_minus[0] + cx) / 2, (bus_minus[1] + cy) / 2 - 30, zl - 8),
                                            (cx - 6, cy - 58, Z_PANEL_BACK - 6)], 1.3, W, blk), 6)
        for c in range(COLS - 1):
            x0 = -half + PANEL / 2 + c * PANEL + 48
            x1 = x0 + PANEL - 96
            cy = half - PANEL / 2 - r * PANEL + 44
            part(cable(f"Ribbon {r}{c}", [(x0, cy, Z_PANEL_BACK - 9), ((x0 + x1) / 2, cy, Z_PANEL_BACK - 14), (x1, cy, Z_PANEL_BACK - 9)], 4.6, W, ribbon, flat=True), 3)
    for k in range(3):                                 # bonnet to the first panel of each row
        cy = half - PANEL / 2 - k * PANEL + 44
        part(cable(f"Ribbon port {k + 1}", [(pi_at[0] - 10 + k * 12, pi_at[1] + 10, pi_at[2] - 14), (-half + 40, cy - 10, zl - 10), (-half + 32, cy, Z_PANEL_BACK - 9)], 4.6, W, ribbon, flat=True), 6)
    for i in range(3):                                 # supply to bars: three 14 AWG pairs
        part(cable(f"Feed + {i}", [(psu_at[0] + PSU[0] / 2 - 12 + i * 6, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12), (bus_plus[0] - 40, bus_plus[1] - 50 + i * 8, zl - 10), (bus_plus[0], bus_plus[1] + 12, zl)], 1.7, W, red), 6)
        part(cable(f"Feed - {i}", [(psu_at[0] + PSU[0] / 2 - 30 + i * 6, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12), (bus_minus[0] - 40, bus_minus[1] - 50 + i * 8, zl - 10), (bus_minus[0], bus_minus[1] - 12, zl)], 1.7, W, blk), 6)
    part(cable("Mains L", [(inlet_at[0], inlet_at[1] + 20, inlet_at[2]), (half - 150, -half + 20, Z_BACK_FRONT + 12), (psu_at[0] + PSU[0] / 2 - 48, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12)], 1.5, W, blk), 6)
    part(cable("Mains N", [(inlet_at[0] - 8, inlet_at[1] + 20, inlet_at[2]), (psu_at[0] + PSU[0] / 2 - 42, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12)], 1.5, W, white), 6)
    part(cable("Pi feed", [(bus_plus[0] - 14, bus_plus[1] + 18, zl), (pi_at[0] - PI[0] / 2 + 11.2, pi_at[1] - PI[1] / 2 - 6, pi_at[2] - 4)], 1.3, W, red), 6)

    # ---- studio ------------------------------------------------------------
    S = cols["Studio"]
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    wallp = bpy.context.active_object
    wallp.name = "Room wall"
    wallp.scale = (6.0, 4.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    wallp.rotation_euler = (math.pi / 2, 0, 0)
    wallp.location = (0, mm(-Z_REAR) + 0.002, 1.6)
    wallp.data.materials.append(plaster)
    link(wallp, S)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    floor = bpy.context.active_object
    floor.name = "Floor"
    floor.scale = (8.0, 8.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    floor.location = (0, -2.5, 0)
    floor.data.materials.append(floor_m)
    link(floor, S)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    sweep = bpy.context.active_object
    sweep.name = "Studio sweep"
    sweep.scale = (8.0, 6.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    sweep.rotation_euler = (math.pi / 2, 0, 0)
    sweep.location = (0, mm(-Z_REAR) + 0.004, 2.0)
    sweep.data.materials.append(studio)
    link(sweep, S)
    sweep.hide_render = True

    world = bpy.data.worlds.new("World")
    sc.world = world
    if hasattr(world, "use_nodes"):
        world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.02, 0.019, 0.018, 1)
    bg.inputs[1].default_value = 1.0

    def area(name, loc, target, power, size, color=(1, 1, 1), size_y=None):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy = power
        ld.size = size
        ld.color = color
        if size_y:
            ld.shape = "RECTANGLE"
            ld.size_y = size_y
        lo = bpy.data.objects.new(name, ld)
        lo.location = loc
        lo.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        sc.collection.objects.link(lo)
        return lo

    lights = {
        "key": area("Key", (-2.2, -2.4, 3.0), (0, 0, 1.45), 420, 2.4, (1.0, 0.96, 0.90)),
        "fill": area("Fill", (2.6, -2.0, 1.4), (0, 0, 1.45), 90, 3.0, (0.9, 0.94, 1.0)),
        "rim": area("Rim", (1.9, 0.6, 2.9), (0.2, 0.0, 1.5), 260, 0.25, (1.0, 0.98, 0.95), size_y=2.0),
        "back": area("Back light", (0.8, 1.9, 2.4), (0, 0.1, 1.45), 300, 1.6),
    }
    lights["back"].hide_render = True

    cam_data = bpy.data.cameras.new("Camera")
    cam_data.lens = 50
    cam_data.sensor_width = 36
    cam = bpy.data.objects.new("Camera", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    return sc, cam, parts, lights, sweep, wallp


def aim(cam, loc, target, lens=50, fstop=None, focus=None):
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = lens
    cam.data.dof.use_dof = fstop is not None
    if fstop:
        cam.data.dof.aperture_fstop = fstop
        cam.data.dof.focus_distance = (Vector(focus or target) - Vector(loc)).length


def explode(parts, amount_mm):
    """Spread the layers along the wall's depth. Borrowed parts hang under a
    pivot turned -90 about x, so their local -y is this model's depth."""
    for o, layer in parts.values():
        if o.parent is not None and o.parent.name.startswith("Atelier"):
            if o.parent.name.startswith("Atelier") and (o.parent is not None):
                o.location.y -= mm(amount_mm) * (2 - layer)
        else:
            o.location.z += mm(amount_mm) * (2 - layer)


def glare(sc):
    """A little bloom off the LEDs. Blender 5 hangs the compositor off the
    scene as a node group. Skipped, not fatal, if the API has moved again."""
    try:
        ng = bpy.data.node_groups.new("Compositing", "CompositorNodeTree")
        rl = ng.nodes.new("CompositorNodeRLayers")
        rl.scene = sc
        out = ng.nodes.new("NodeGroupOutput")
        ng.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        g = ng.nodes.new("CompositorNodeGlare")
        for attr, val in (("glare_type", "BLOOM"), ("threshold", 1.2), ("size", 6), ("mix", -0.3)):
            try:
                setattr(g, attr, val)
            except Exception:
                pass
        for name, val in (("Threshold", 1.2), ("Strength", 0.06), ("Size", 0.5)):
            if name in g.inputs:
                try:
                    g.inputs[name].default_value = val
                except Exception:
                    pass
        ng.links.new(rl.outputs["Image"], g.inputs["Image"])
        ng.links.new(g.outputs["Image"], out.inputs[0])
        if hasattr(sc, "compositing_node_group"):
            sc.compositing_node_group = ng
        else:
            raise RuntimeError("no compositing_node_group on the scene")
        print("glare on")
    except Exception as exc:                          # noqa: BLE001
        print("glare skipped:", exc)


def render(sc, path, samples, res=(2000, 1400)):
    sc.render.engine = "CYCLES"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.refresh_devices()
        for d in prefs.devices:
            d.use = True
        sc.cycles.device = "GPU"
    except Exception as exc:                          # noqa: BLE001
        print("cycles gpu:", exc)
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 12
    sc.cycles.transmission_bounces = 16
    sc.cycles.transparent_max_bounces = 16
    sc.cycles.glossy_bounces = 8
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.view_settings.view_transform = "AgX"
    sc.view_settings.look = "AgX - Medium High Contrast"
    sc.view_settings.exposure = 0.0
    sc.render.image_settings.file_format = "PNG"
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("rendered", path)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="design/renders")
    ap.add_argument("--face", default="")
    ap.add_argument("--samples", type=int, default=200)
    ap.add_argument("--views", default="hero,front,detail,back,exploded,room")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)

    sc, cam, parts, lights, sweep, wallp = build(os.path.abspath(args.face) if args.face else "")
    glare(sc)
    views = args.views.split(",")
    C = (0.0, 0.0, mm(WALL_H))

    def studio(on):
        sweep.hide_render = not on
        wallp.hide_render = on

    if "hero" in views:
        studio(True)
        aim(cam, (-0.95, -1.35, 1.62), (0.0, 0.0, mm(WALL_H) - 0.01), lens=55, fstop=4.0)
        render(sc, os.path.join(args.out, "wall-hero.png"), args.samples)
    if "front" in views:
        studio(True)
        aim(cam, (0.0, -1.55, mm(WALL_H)), C, lens=60)
        render(sc, os.path.join(args.out, "wall-front.png"), args.samples)
    if "detail" in views:
        studio(True)
        # the top left corner of the window, on the frame's front plane
        corner = (-WINDOW / 2000, mm(-Z_REAR) - mm(Z_FRONT), mm(WALL_H) + WINDOW / 2000)
        aim(cam, (corner[0] - 0.26, corner[1] - 0.34, corner[2] + 0.12), corner, lens=85, fstop=5.6, focus=corner)
        render(sc, os.path.join(args.out, "wall-detail.png"), args.samples)
    if "back" in views:
        studio(True)
        lights["back"].hide_render = False
        sweep.hide_render = True
        hidden = tuple(n for n in parts if n.startswith(("Back panel", "Cleat", "Badge", "Back screw", "Vent", "Wall pad")))
        for name in hidden:
            parts[name][0].hide_render = True
        aim(cam, (0.62, 0.95, 1.80), (0.0, 0.05, mm(WALL_H) - 0.03), lens=45)
        render(sc, os.path.join(args.out, "wall-back.png"), args.samples)
        for name in hidden:
            parts[name][0].hide_render = False
        lights["back"].hide_render = True
    if "exploded" in views:
        sweep.hide_render = True
        wallp.hide_render = True
        explode(parts, 110)
        aim(cam, (-1.25, -1.35, 1.95), (0.0, 0.10, mm(WALL_H) - 0.02), lens=45)
        render(sc, os.path.join(args.out, "wall-exploded.png"), args.samples)
        explode(parts, -110)
    if "room" in views:
        studio(False)
        aim(cam, (-0.85, -1.9, 1.40), (0.0, 0.0, mm(WALL_H) - 0.05), lens=40)
        render(sc, os.path.join(args.out, "wall-room.png"), args.samples)

    studio(False)
    blend = os.path.join(args.out, "album-wall.blend")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend))
    print("saved", blend)
    print("outer %.0f mm square, %.1f mm deep; window %.0f; LEDs %.0f; acrylic %.0f"
          % (OUTER, FRAME_D, WINDOW, FACE, ACRYLIC))


if __name__ == "__main__":
    main()
