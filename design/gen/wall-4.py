"""The Tessera wall, as a Blender model. The build, not the aspiration.

A 24 inch plywood square with a steel skin on its face, painted matte black.
The nine panels hold themselves to the steel with the magnetic feet that ship
in their boxes. A sheet of smoked acrylic floats an inch in front on four sign
standoffs. Everything electrical lives on the back, in the gap two furring
blocks and the cleat hold open. Nothing is cut but three squares and four
holes, and the whole of it is about a hundred dollars over what is already on
the bench.

The walnut shadow box this replaces is kept at wall_model_walnut.py. It is the
upgrade path: this carcass is what it would go around.

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
PANEL_SHELL = 159.8            # VERIFIED  Waveshare P2_5 64x64 DWG (official GitHub)
SHELL_D = 12.0                 # VERIFIED  same drawing: rear shell depth
PANEL_M3 = ((-45, -73), (45, -73), (-73, -45), (73, -45),
            (-73, 45), (73, 45), (-45, 73), (45, 73))
                               # VERIFIED  same drawing: eight M3 points from centre
MAG_FOOT_H = 3.0               # TYPICAL   four magnetic feet ship with each panel
                               #           (manual); their height is not stated.
                               #           THE ONE NUMBER TO MEASURE FIRST.
COLS = ROWS = 3
FACE = PANEL * COLS            # 480

# --- the board ---------------------------------------------------------------
BOARD = 609.6                  # LISTING   24 in: the size both sheets come in
PLY_T = 12.7                   # LISTING   1/2 in plywood or MDF project panel
STEEL_T = 0.76                 # LISTING   22 gauge steel sheet, glued to the face
BORDER = (BOARD - FACE) / 2    # 64.8: what shows around the picture, painted black

# --- the glass ---------------------------------------------------------------
ACRYLIC = 609.6                # LISTING   the same 24 in square, smoked grey
ACR_T = 3.175                  # LISTING   1/8 in
STANDOFF_BARREL = 25.4         # LISTING   1 in sign standoffs, four of them
STANDOFF_D = 25.4              # LISTING   1 in diameter
STANDOFF_INSET = 30.0          # DESIGN    from the board's edge to the barrel centre

# --- hanging -----------------------------------------------------------------
FURRING = 19.05                # LISTING   1 x 3 furring strip, 3/4 in actual
FURRING_D = 63.5               # LISTING   its 2-1/2 in face, stood on edge: the
                               #           gap the electronics live in. A 1 x 2
                               #           gives 38.1, which is EXACTLY the bus
                               #           bar's height with its cover on, so the
                               #           wider strip is the same $2 and the
                               #           difference between a fit and a scrape.
CLEAT_L = 304.8                # LISTING   OOK 533208: 12 in
CLEAT_W, CLEAT_T = 38.1, 2.0   # LISTING   1.5 in tall; stands 1/8 in off the wall
CLEAT_PROJ = 3.175             # LISTING   that 1/8 in

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
IDC = (20.3, 8.9, 9.0)         # TYPICAL   2x8 shrouded box header outline
PI_STACK = 3 + PI[2] + RISER_BODY + RISER_PIN + BONNET[2] + IDC[2]
                               # the tallest thing on the back, and what decides
                               # how deep the furring has to be
BUSBAR = (137.2, 22.9, 38.1)   # LISTING   RVBOATPAT dimension image: 5.4 x 0.9 x
                               #           1.5 in with its cover on, 12 x M4
FUSE_HOLDER = (36.0, 14.0, 14.0)   # TYPICAL  NI-FH01 body; the listing gives only
                               #           the fuse (19.1 x 18.5 x 5.1) and 12 in leads
INLET = (50.0, 30.0, 30.0)     # LISTING   Antrader: approx 5 x 3 x 3 cm
SL22_D, SL22_T = 22.0, 5.0     # VERIFIED  Ametherm datasheet: 22 max dia, 5 thick
MIC = (22.2, 18.3, 7.0)        # VERIFIED  Adafruit 3367
LUX = (25.5, 17.7, 4.6)        # VERIFIED  Adafruit 4162

# --- depth bookkeeping, from the LED face (z = 0) back (negative z) ---------
Z_PANEL_BACK = -PANEL_T
Z_STEEL_FRONT = Z_PANEL_BACK - MAG_FOOT_H
Z_STEEL_BACK = Z_STEEL_FRONT - STEEL_T
Z_PLY_BACK = Z_STEEL_BACK - PLY_T
Z_WALL = Z_PLY_BACK - FURRING_D - CLEAT_PROJ
Z_ACR_BACK = Z_STEEL_FRONT + STANDOFF_BARREL     # the standoff sets this
Z_ACR_FRONT = Z_ACR_BACK + ACR_T
AIR_GAP = Z_ACR_BACK                             # LED face to the glass
DEPTH = Z_ACR_FRONT - Z_PLY_BACK                 # what the object is, edge on
CLEARANCE = FURRING_D - max(PSU[2], PI_STACK, BUSBAR[2])

ATELIER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "atelier-v2", "Tessera-Atelier.blend")
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
    root.location = (0, mm(-Z_WALL), mm(WALL_H))

    cols = {n: collection(n) for n in ("Panels", "Glass", "Board", "Electronics", "Wiring", "Studio")}
    parts = {}

    black = material("Panel plastic", (0.02, 0.02, 0.02), 0.55)
    paint = material("Matte black paint", (0.016, 0.016, 0.017), 0.82)
    pcb_dark = material("PCB dark", (0.012, 0.03, 0.02), 0.5)
    pcb_pi = material("PCB Pi green", (0.02, 0.09, 0.035), 0.45)
    ic = material("IC", (0.03, 0.03, 0.03), 0.35)
    alu = brushed_material("Aluminium", (0.80, 0.80, 0.82), 0.30)
    anod = brushed_material("Black anodised", (0.045, 0.045, 0.048), 0.36, 0.5)
    steel = brushed_material("Bare steel", (0.62, 0.63, 0.64), 0.42, 0.3)
    tin = brushed_material("Tinned copper", (0.75, 0.76, 0.74), 0.35)
    nylon = material("Nylon", (0.90, 0.88, 0.82), 0.7)
    red = material("Red lead", (0.55, 0.03, 0.02), 0.5)
    blk = material("Black lead", (0.012, 0.012, 0.012), 0.5)
    ribbon = material("Ribbon", (0.30, 0.30, 0.33), 0.7)
    white = material("White plastic", (0.85, 0.85, 0.82), 0.5)
    smoke = material("Smoked acrylic", (0.30, 0.30, 0.32), 0.02, transmission=1.0, ior=1.49)
    ply = plywood_material()
    led = led_material(face_png)
    plaster = material("Plaster", (0.56, 0.50, 0.43), 0.9)
    studio_m = material("Studio", (0.045, 0.043, 0.040), 0.55)
    floor_m = material("Studio floor", (0.035, 0.034, 0.032), 0.28)

    def part(o, layer):
        o.parent = root
        parts[o.name] = (o, layer)
        return o

    half = FACE / 2

    # ---- the board: plywood, a steel skin on its face, both painted ------
    part(box("Plywood board", (BOARD, BOARD, PLY_T), (0, 0, Z_STEEL_BACK - PLY_T / 2),
             cols["Board"], ply, bevel=0.6), 5)
    part(box("Steel skin", (BOARD, BOARD, STEEL_T), (0, 0, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2),
             cols["Board"], paint), 5)
    # the mark: the app's lattice, a stencil and a fingertip of grey paint on
    # the bottom border. It costs nothing and it is the only ornament.
    for i in range(7):
        for j in range(7):
            lit = (i, j) == (4, 2)
            g = 0.30 if lit else 0.14
            m = material(f"Stencil {lit}", (g, g, g * 0.95), 0.8)
            part(box(f"Mark {i}{j}", (2.0, 2.0, 0.05), ((i - 3) * 3.0, -half - BORDER / 2 + (j - 3) * 3.0,
                     Z_STEEL_FRONT + 0.03), cols["Board"], m), 5)

    # ---- nine panels, held on by their own magnets -----------------------
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            n = r * COLS + c + 1
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
            zb = -PANEL_T + 5.5
            for k, dx in enumerate((-48, 48)):
                part(box(f"Panel {n} HUB75 {'in' if k == 0 else 'out'}", IDC,
                         (cx + dx, cy + 44, zb), cols["Panels"], black), 3)
            part(box(f"Panel {n} VH4", (12.0, 9.0, 8.0), (cx, cy - 58, zb), cols["Panels"], white), 3)
            # the feet, on four of the drawing's eight M3 points
            for k, (mx, my) in enumerate((PANEL_M3[0], PANEL_M3[1], PANEL_M3[6], PANEL_M3[7])):
                part(cylinder(f"Panel {n} magnet {k}", 5.0, MAG_FOOT_H,
                              (cx + mx, cy + my, -PANEL_T - MAG_FOOT_H / 2),
                              cols["Panels"], tin, verts=24), 3)
    borrow("P Panels", root, parts, 3, keep=lambda n: "PCB face" not in n)

    # ---- the glass, floating on four standoffs ---------------------------
    part(box("Smoked acrylic", (ACRYLIC, ACRYLIC, ACR_T), (0, 0, (Z_ACR_BACK + Z_ACR_FRONT) / 2),
             cols["Glass"], smoke, bevel=0.4), 1)
    for i, (sx, sy) in enumerate(((-1, 1), (1, 1), (-1, -1), (1, -1))):
        x = sx * (BOARD / 2 - STANDOFF_INSET)
        y = sy * (BOARD / 2 - STANDOFF_INSET)
        part(cylinder(f"Standoff barrel {i}", STANDOFF_D / 2, STANDOFF_BARREL,
                      (x, y, Z_STEEL_FRONT + STANDOFF_BARREL / 2), cols["Glass"], anod), 2)
        part(cylinder(f"Standoff cap {i}", STANDOFF_D / 2, 4.0,
                      (x, y, Z_ACR_FRONT + 2.0), cols["Glass"], anod), 1)

    # ---- hanging: two blocks and the cleat, two feet at the bottom -------
    for i, sx in enumerate((-1, 1)):
        part(box(f"Cleat block {i}", (120, FURRING, FURRING_D),
                 (sx * 90, BOARD / 2 - 60, Z_PLY_BACK - FURRING_D / 2), cols["Board"], ply), 7)
        part(box(f"Foot {i}", (60, FURRING, FURRING_D),
                 (sx * 220, -BOARD / 2 + 30, Z_PLY_BACK - FURRING_D / 2), cols["Board"], ply), 7)
    c1 = part(box("Cleat (frame)", (CLEAT_L, CLEAT_W, CLEAT_T), (0, BOARD / 2 - 60, Z_PLY_BACK - FURRING_D - CLEAT_T / 2),
                  cols["Board"], alu, bevel=0.4), 7)
    c1.rotation_euler = (math.radians(30), 0, 0)
    c2 = part(box("Cleat (wall)", (CLEAT_L, CLEAT_W, CLEAT_T), (0, BOARD / 2 - 78, Z_WALL + CLEAT_T / 2 + 1),
                  cols["Board"], alu, bevel=0.4), 8)
    c2.rotation_euler = (math.radians(30), 0, 0)

    # ---- electronics, on the open back -----------------------------------
    E = cols["Electronics"]
    zc_top = Z_PLY_BACK - 1.0
    psu_at = (-40, -BOARD / 2 + PSU[1] / 2 + 40, zc_top - PSU[2] / 2)
    borrow("E Power", root, parts, 6, centre=psu_at,
           keep=lambda n: "inlet" not in n.lower() and "iec" not in n.lower())
    pi_at = (-BOARD / 2 + 90, BOARD / 2 - 120, zc_top - PI_STACK / 2)
    borrow("D Controller", root, parts, 6, centre=pi_at)
    bus_plus = (BOARD / 2 - 120, 130)
    bus_minus = (BOARD / 2 - 120, 60)
    borrow("E Bus bars", root, parts, 6, centre=(BOARD / 2 - 120, 95, zc_top - 14))
    fuse_c = (60, 0, zc_top - 8)
    borrow("U Unresolved fit", root, parts, 6, centre=fuse_c,
           keep=lambda n: any(k in n.lower() for k in ("fuse", "nilight", "heat", "shrink", "10a", "butt")))
    inlet_at = (BOARD / 2 - 70, -BOARD / 2 + 24, zc_top - INLET[2] / 2)
    part(box("C14 inlet module", INLET, inlet_at, E, black, bevel=1.0), 6)
    part(cylinder("SL22 thermistor", SL22_D / 2, SL22_T, (BOARD / 2 - 140, -BOARD / 2 + 30, zc_top - 8),
                  E, black, axis="Z", verts=24), 6)
    part(box("USB microphone", MIC, (-BOARD / 2 + 40, -BOARD / 2 + 40, zc_top - 5), E, black, bevel=1.0), 6)
    part(box("VEML7700 lux sensor", LUX, (0, BOARD / 2 - 30, zc_top - 3), E, pcb_dark), 6)
    # the one bond that matters on an open back: the steel skin to -V
    part(cable("Skin bond", [(BOARD / 2 - 200, 40, Z_PLY_BACK - 6), (bus_minus[0] - 30, bus_minus[1], zc_top - 10)],
               1.3, cols["Wiring"], blk), 6)

    # ---- wiring: round the edge, then inside the panels' shells ----------
    W = cols["Wiring"]
    zl = zc_top - 10
    edge = BOARD / 2 + 6
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            k = r * COLS + c
            fat = (fuse_c[0] - 41 + (k % 3) * 41, fuse_c[1] + 35 - (k // 3) * 35)
            # bar to fuse, on the back
            part(cable(f"Drop {k + 1} bar", [(bus_plus[0] - 50, bus_plus[1] - 30 + (k % 6) * 8, zl),
                                             (fat[0] + 22, fat[1], zl - 2)], 1.3, W, red), 6)
            # fuse round the bottom edge to the panel's plug, on the front
            part(cable(f"Drop {k + 1} +", [(fat[0] - 22, fat[1], zl - 2),
                                           (fat[0] - 40, -edge + 14, zl),
                                           (cx + 20, -edge, (zl + Z_PANEL_BACK) / 2),
                                           (cx + 10, -half - 20, Z_PANEL_BACK - 5),
                                           (cx + 6, cy - 58, Z_PANEL_BACK - 6)], 1.3, W, red), 6)
            part(cable(f"Drop {k + 1} -", [(bus_minus[0] - 40, bus_minus[1] - 20 + (k % 6) * 6, zl),
                                           (cx + 60, -edge + 10, zl),
                                           (cx - 10, -edge, (zl + Z_PANEL_BACK) / 2),
                                           (cx - 10, -half - 18, Z_PANEL_BACK - 5),
                                           (cx - 6, cy - 58, Z_PANEL_BACK - 6)], 1.3, W, blk), 6)
        # panel to panel along the row, inside the 12 mm shells
        for c in range(COLS - 1):
            x0 = -half + PANEL / 2 + c * PANEL + 48
            x1 = x0 + PANEL - 96
            cy = half - PANEL / 2 - r * PANEL + 44
            part(cable(f"Ribbon {r}{c}", [(x0, cy, Z_PANEL_BACK - 9), ((x0 + x1) / 2, cy, Z_PANEL_BACK - 13),
                                          (x1, cy, Z_PANEL_BACK - 9)], 4.6, W, ribbon, flat=True), 3)
    # the bonnet's three ports, round the left edge to the first panel of each row
    for k in range(3):
        cy = half - PANEL / 2 - k * PANEL + 44
        part(cable(f"Ribbon port {k + 1}", [(pi_at[0] - 10 + k * 14, pi_at[1] - 10, pi_at[2] - 10),
                                            (-edge + 20, pi_at[1] - 60, zl),
                                            (-edge, cy + 10, (zl + Z_PANEL_BACK) / 2),
                                            (-half - 20, cy, Z_PANEL_BACK - 9),
                                            (-half + 32, cy, Z_PANEL_BACK - 9)], 4.6, W, ribbon, flat=True), 3)
    for i in range(3):
        part(cable(f"Feed + {i}", [(psu_at[0] + PSU[0] / 2 - 12 + i * 6, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12),
                                   (bus_plus[0] - 70, bus_plus[1] - 60 + i * 8, zl - 6),
                                   (bus_plus[0], bus_plus[1] + 10, zl)], 1.7, W, red), 6)
        part(cable(f"Feed - {i}", [(psu_at[0] + PSU[0] / 2 - 30 + i * 6, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12),
                                   (bus_minus[0] - 70, bus_minus[1] - 60 + i * 8, zl - 6),
                                   (bus_minus[0], bus_minus[1] - 10, zl)], 1.7, W, blk), 6)
    part(cable("Mains L", [(inlet_at[0], inlet_at[1] + 16, inlet_at[2]),
                           (BOARD / 2 - 140, -BOARD / 2 + 30, zc_top - 8),
                           (psu_at[0] + PSU[0] / 2 - 48, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12)], 1.5, W, blk), 6)
    part(cable("Mains N", [(inlet_at[0] - 10, inlet_at[1] + 16, inlet_at[2]),
                           (psu_at[0] + PSU[0] / 2 - 42, psu_at[1] + PSU[1] / 2 - 9, psu_at[2] - 12)], 1.5, W, white), 6)
    part(cable("Pi feed", [(bus_plus[0] - 20, bus_plus[1] + 14, zl),
                           (pi_at[0] + 30, pi_at[1] - 20, pi_at[2])], 1.3, W, red), 6)

    # ---- studio ------------------------------------------------------------
    S = cols["Studio"]
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    wallp = bpy.context.active_object
    wallp.name = "Room wall"
    wallp.scale = (6.0, 4.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    wallp.rotation_euler = (math.pi / 2, 0, 0)
    wallp.location = (0, mm(-Z_WALL) + 0.002, 1.6)
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
    sweep.location = (0, mm(-Z_WALL) + 0.004, 2.0)
    sweep.data.materials.append(studio_m)
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
        # Smoked acrylic is a mirror as much as a filter. A big soft key
        # lands its own reflection across the picture, so the key is small
        # and high and off to the side, where its reflection falls outside
        # the sheet, and the sheet is lit by bounce instead.
        "key": area("Key", (-2.5, -1.0, 3.4), (-0.3, 0.2, 1.2), 220, 0.9, (1.0, 0.96, 0.90)),
        # The mirror direction off the sheet toward the hero camera points
        # right, forward and slightly down, so a fill placed there lands its
        # own rectangle across the picture. It lives high instead.
        "fill": area("Fill", (2.6, -1.1, 3.0), (0.4, 0.1, 1.2), 130, 1.6, (0.9, 0.94, 1.0)),
        "rim": area("Rim", (1.9, 0.6, 2.9), (0.2, 0.0, 1.5), 220, 0.25, (1.0, 0.98, 0.95), size_y=2.0),
        "back": area("Back light", (0.8, 1.9, 2.4), (0, 0.1, 1.45), 140, 1.6),
    }
    lights["back"].hide_render = True

    cam_data = bpy.data.cameras.new("Camera")
    cam_data.lens = 50
    cam_data.sensor_width = 36
    cam = bpy.data.objects.new("Camera", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    return sc, cam, parts, lights, sweep, wallp


def plywood_material():
    """Birch ply on the edges, and its face is painted anyway."""
    m, nt, bsdf = principled("Plywood")
    bsdf.inputs["Roughness"].default_value = 0.72
    tex = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (1.0, 1.0, 60.0)     # plies stack in z
    nt.links.new(tex.outputs["Object"], mapping.inputs["Vector"])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 8.0
    noise.inputs["Detail"].default_value = 6.0
    nt.links.new(mapping.outputs[0], noise.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.14, 0.095, 0.052, 1)
    ramp.color_ramp.elements[1].color = (0.26, 0.185, 0.105, 1)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return m


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
        aim(cam, (-0.95, -1.40, 1.62), (0.0, 0.0, mm(WALL_H) - 0.01), lens=55, fstop=4.0)
        render(sc, os.path.join(args.out, "wall-hero.png"), args.samples)
    if "front" in views:
        studio(True)
        aim(cam, (0.0, -1.70, mm(WALL_H)), C, lens=60)
        render(sc, os.path.join(args.out, "wall-front.png"), args.samples)
    if "detail" in views:
        studio(True)
        # the top left standoff, where the glass, the barrel, the black
        # border and the first panel all meet
        x = -(BOARD / 2 - STANDOFF_INSET) / 1000
        z = mm(WALL_H) + (BOARD / 2 - STANDOFF_INSET) / 1000
        corner = (x, mm(-Z_WALL) - mm(Z_ACR_FRONT), z)
        aim(cam, (corner[0] - 0.20, corner[1] - 0.30, corner[2] + 0.10), corner, lens=85, fstop=5.6, focus=corner)
        render(sc, os.path.join(args.out, "wall-detail.png"), args.samples)
    if "back" in views:
        studio(True)
        lights["back"].hide_render = False
        sweep.hide_render = True
        # nothing to remove: the back is open
        aim(cam, (0.62, 0.95, 1.80), (0.0, 0.05, mm(WALL_H) - 0.03), lens=45)
        render(sc, os.path.join(args.out, "wall-back.png"), args.samples)
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
    print("board %.0f mm square, %.1f mm deep with the glass; LEDs %.0f; border %.1f"
          % (BOARD, DEPTH, FACE, BORDER))
    print("glass floats %.1f mm over the LEDs; back gap %.1f mm, tallest part %.1f mm, clearance %.1f mm"
          % (AIR_GAP, FURRING_D, max(PSU[2], PI_STACK, BUSBAR[2]), CLEARANCE))


if __name__ == "__main__":
    main()
