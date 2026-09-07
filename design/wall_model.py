"""The finished wall, as a Blender model.

Nine Waveshare P2.5 64x64 panels behind an opal and smoked acrylic stack, in
a walnut shadow box with everything the wall needs living behind the panels:
the mount plate, the LRS-350-5, the Pi 5 with the Triple Bonnet, bus bars,
nine fused drops, the inlet, and a French cleat. Every dimension is a number
at the top of this file, in millimetres, so the model follows the build and
not the other way round.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python design/wall_model.py -- --out design/renders --face face192.png

Renders four views and saves the .blend beside them. Where a dimension was
never measured it says so in the comment beside it.
"""
import argparse
import math
import os
import sys

import bpy
from mathutils import Vector

# ----------------------------------------------------------------- numbers
# Everything in millimetres. mm() turns them into Blender metres.

TILE_PX = 64
PITCH = 2.5                    # LED pitch
PANEL = TILE_PX * PITCH        # 160: measured outline, Waveshare manual
PANEL_T = 14.5                 # panel thickness, Waveshare manual drawing 3.1
COLS = ROWS = 3
FACE = PANEL * COLS            # 480

GAP_AIR = 2.0                  # LED face to the opal sheet
OPAL_T = 3.0                   # opal acrylic
SMOKE_T = 3.0                  # smoked ND acrylic
ACRYLIC = FACE + 6             # the sheets sit 3 mm under the lip all round
LIP = 3.0                      # frame lip over the acrylic edge, front
LIP_T = 3.0

FRAME_W = 28.0                 # rail width seen from the front
STANDOFF = 20.0                # nylon standoff, panel back to mount plate.
                               # NOT YET MEASURED: depends on how far the
                               # harness terminals and fuse holders stand off
                               # the panel back. 20 is the guess in PARTS.md.
PLATE_T = 6.0                  # PVC mount plate
PLATE = FACE + 16              # 496: inside the frame, over the panels
CAVITY = 38.0                  # behind the plate: the PSU is 30 tall
BACK_T = 6.0                   # back board

# depth bookkeeping, from the LED face (z = 0) backwards (negative z)
Z_PANEL_BACK = -PANEL_T
Z_PLATE_FRONT = Z_PANEL_BACK - STANDOFF
Z_PLATE_BACK = Z_PLATE_FRONT - PLATE_T
Z_BACK_FRONT = Z_PLATE_BACK - CAVITY
Z_BACK = Z_BACK_FRONT - BACK_T                # the frame's back face
Z_FRONT = GAP_AIR + OPAL_T + SMOKE_T + LIP_T  # the frame's front face
DEPTH = Z_FRONT - Z_BACK

# the electronics, from their datasheets or their boxes
PSU = (215.0, 115.0, 30.0)     # Mean Well LRS-350-5
PI = (85.0, 56.0, 17.0)        # Pi 5 with the Active Cooler
BONNET = (65.0, 56.0, 12.0)    # Triple Bonnet on a riser; the outline is the
                               # bonnet form factor, not measured
BUSBAR = (150.0, 20.0, 14.0)   # RVBOATPAT pair, approximate
FUSE = (38.0, 12.0, 14.0)      # inline ATC holder body
INLET = (48.0, 28.0, 30.0)     # C14 with switch and fuse, module behind the rail
CLEAT_W, CLEAT_T, CLEAT_L = 40.0, 12.0, 400.0

WALL_H = 1500.0                # the wall's centre off the floor

# ------------------------------------------------------------------ helpers

def mm(v):
    return v / 1000.0


def clean():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.system = "METRIC"
    sc.unit_settings.length_unit = "MILLIMETERS"
    sc.unit_settings.scale_length = 1.0
    return sc


def collection(name, parent=None):
    col = bpy.data.collections.new(name)
    (parent or bpy.context.scene.collection).children.link(col)
    return col


def link(obj, col):
    for c in list(obj.users_collection):
        c.objects.unlink(obj)
    col.objects.link(obj)
    return obj


def material(name, base=(0.5, 0.5, 0.5), rough=0.5, metal=0.0, transmission=0.0,
             ior=1.45, emit=None, emit_strength=0.0, alpha=1.0):
    m = bpy.data.materials.get(name)
    if m:
        return m
    m = bpy.data.materials.new(name)
    if hasattr(m, "use_nodes"):
        m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    if bsdf is None:
        bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
        out = nt.nodes.new("ShaderNodeOutputMaterial")
        nt.links.new(bsdf.outputs[0], out.inputs[0])
    bsdf.inputs["Base Color"].default_value = (*base, 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    bsdf.inputs["IOR"].default_value = ior
    if "Transmission Weight" in bsdf.inputs:
        bsdf.inputs["Transmission Weight"].default_value = transmission
    bsdf.inputs["Alpha"].default_value = alpha
    if emit is not None:
        bsdf.inputs["Emission Color"].default_value = (*emit, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emit_strength
    return m


def box(name, size, at, col, mat=None, bevel=0.0):
    """A cuboid. size and at in mm; at is the CENTRE."""
    bpy.ops.mesh.primitive_cube_add(size=1.0)
    o = bpy.context.active_object
    o.name = name
    # Scale is baked while the object still sits at the origin, so the mesh
    # stays centred on its own origin: the mitre shear and the rail
    # rotations both depend on that, and applying with the location set
    # baked the position into the mesh and left every origin at zero.
    o.scale = (mm(size[0]), mm(size[1]), mm(size[2]))
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    o.location = (mm(at[0]), mm(at[1]), mm(at[2]))
    if mat:
        o.data.materials.append(mat)
    if bevel:
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width = mm(bevel)
        b.segments = 3
        b.limit_method = "ANGLE"
    link(o, col)
    return o


def cylinder(name, r, h, at, col, mat=None, axis="Z"):
    bpy.ops.mesh.primitive_cylinder_add(radius=mm(r), depth=mm(h), vertices=24)
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


def frame_rail(name, length, width, depth, at, rot_z, col, mat):
    """One rail of the frame, mitred: a box with its two ends cut at 45.

    The mitre is done by shearing the end vertices rather than booleans,
    because a boolean on four thin rails is where Blender models go to die.
    """
    o = box(name, (length, width, depth), at, col, mat, bevel=1.2)
    me = o.data
    half_l, half_w = mm(length) / 2, mm(width) / 2
    for v in me.vertices:
        # vertices at the OUTER edge (y = +half_w) keep the full length,
        # the inner edge (y = -half_w) is shorter by the width on each end
        if v.co.y < 0:
            v.co.x = math.copysign(half_l - 2 * half_w, v.co.x)
    o.rotation_euler = (0, 0, rot_z)
    return o


def uv_square(obj, u0, v0, u1, v1):
    me = obj.data
    uv = me.uv_layers.new(name="UVMap") if not me.uv_layers else me.uv_layers[0]
    corners = {(-1, -1): (u0, v0), (1, -1): (u1, v0), (1, 1): (u1, v1), (-1, 1): (u0, v1)}
    for poly in me.polygons:
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            key = (1 if co.x > 0 else -1, 1 if co.y > 0 else -1)
            uv.data[li].uv = corners[key]


def led_material(face_png):
    """The LED face: the picture, sampled pixel for pixel, shown as one lit
    disc per LED on black. Same idea as the app's emitters."""
    m = bpy.data.materials.new("LED face")
    if hasattr(m, "use_nodes"):
        m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.inputs["Base Color"].default_value = (0.01, 0.01, 0.01, 1)
    bsdf.inputs["Roughness"].default_value = 0.5
    nt.links.new(bsdf.outputs[0], out.inputs[0])

    tex = nt.nodes.new("ShaderNodeTexCoord")
    img = nt.nodes.new("ShaderNodeTexImage")
    img.interpolation = "Closest"
    if face_png and os.path.exists(face_png):
        img.image = bpy.data.images.load(face_png)
    nt.links.new(tex.outputs["UV"], img.inputs["Vector"])

    # the dot mask: one disc per LED cell, radius 0.38 of the pitch
    scale = nt.nodes.new("ShaderNodeVectorMath")
    scale.operation = "SCALE"
    scale.inputs["Scale"].default_value = TILE_PX * COLS       # cells across the face
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
    disc.inputs[1].default_value = 0.38
    nt.links.new(length.outputs["Value"], disc.inputs[0])

    mul = nt.nodes.new("ShaderNodeMix")
    mul.data_type = "RGBA"
    mul.blend_type = "MULTIPLY"
    mul.inputs["Factor"].default_value = 1.0
    nt.links.new(img.outputs["Color"], mul.inputs[6])
    grey = nt.nodes.new("ShaderNodeCombineColor")
    nt.links.new(disc.outputs[0], grey.inputs[0])
    nt.links.new(disc.outputs[0], grey.inputs[1])
    nt.links.new(disc.outputs[0], grey.inputs[2])
    nt.links.new(grey.outputs[0], mul.inputs[7])
    nt.links.new(mul.outputs[2], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 28.0
    return m


def wood_material():
    m = bpy.data.materials.new("Walnut")
    if hasattr(m, "use_nodes"):
        m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = 0.42
    tex = nt.nodes.new("ShaderNodeTexCoord")
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (1.0, 14.0, 1.0)      # grain along x
    nt.links.new(tex.outputs["Object"], mapping.inputs["Vector"])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 18.0
    noise.inputs["Detail"].default_value = 6.0
    nt.links.new(mapping.outputs[0], noise.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.075, 0.040, 0.024, 1)   # walnut, not beech
    ramp.color_ramp.elements[1].color = (0.19, 0.105, 0.058, 1)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return m


def cable(name, points, radius, col, mat, flat=False):
    cu = bpy.data.curves.new(name, "CURVE")
    cu.dimensions = "3D"
    cu.bevel_depth = mm(radius)
    cu.bevel_resolution = 3
    sp = cu.splines.new("BEZIER")
    sp.bezier_points.add(len(points) - 1)
    for bp, p in zip(sp.bezier_points, points):
        bp.co = Vector((mm(p[0]), mm(p[1]), mm(p[2])))
        bp.handle_left_type = bp.handle_right_type = "AUTO"
    o = bpy.data.objects.new(name, cu)
    if flat:
        o.scale = (1, 1, 0.25)
    cu.materials.append(mat)
    link(o, col)
    return o


# -------------------------------------------------------------------- build

def build(face_png):
    sc = clean()
    root = bpy.data.objects.new("Wall", None)
    sc.collection.objects.link(root)
    # local +Z (out of the face) becomes world -Y, local +Y becomes world up
    root.rotation_euler = (math.pi / 2, 0, 0)
    root.location = (0, mm(-Z_BACK), mm(WALL_H))

    col_panels = collection("Panels")
    col_glass = collection("Acrylic")
    col_frame = collection("Frame")
    col_inside = collection("Inside")
    col_room = collection("Room")
    parts = {}          # name -> (object, explode layer)

    plastic = material("Panel plastic", (0.02, 0.02, 0.02), 0.6)
    pcb = material("PCB", (0.02, 0.07, 0.03), 0.5)
    alu = material("Aluminium", (0.78, 0.78, 0.80), 0.35, metal=1.0)
    brass = material("Brass", (0.83, 0.62, 0.25), 0.28, metal=1.0)
    nylon = material("Nylon", (0.92, 0.90, 0.84), 0.7)
    pvc = material("PVC plate", (0.09, 0.09, 0.09), 0.8)
    red = material("Red lead", (0.6, 0.03, 0.02), 0.5)
    black = material("Black lead", (0.01, 0.01, 0.01), 0.5)
    ribbon = material("Ribbon", (0.35, 0.35, 0.38), 0.7)
    # IOR 1.0: a thin sheet a few millimetres off the LEDs bends nothing worth
    # drawing, and at 1.49 the two sheets turned into a mirror of the lights
    # that swallowed the picture. The opal keeps a little transmission
    # roughness, which is what it does to the dots; the smoked sheet is a
    # neutral density filter and behaves like one.
    opal = material("Opal acrylic", (0.96, 0.96, 0.96), 0.10, transmission=1.0, ior=1.0)
    smoke = material("Smoked acrylic", (0.45, 0.45, 0.47), 0.02, transmission=1.0, ior=1.0)
    walnut = wood_material()
    led = led_material(face_png)
    plaster = material("Plaster", (0.60, 0.53, 0.45), 0.92)
    oak = material("Oak floor", (0.40, 0.26, 0.15), 0.55)
    dark = material("Dark object", (0.05, 0.05, 0.05), 0.4)

    def part(o, layer):
        o.parent = root
        parts[o.name] = (o, layer)
        return o

    # ---- nine panels ---------------------------------------------------
    half = FACE / 2
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            n = r * COLS + c + 1
            body = box(f"Panel {n} body", (PANEL - 0.6, PANEL - 0.6, PANEL_T),
                       (cx, cy, -PANEL_T / 2), col_panels, plastic, bevel=0.8)
            part(body, 3)
            bpy.ops.mesh.primitive_plane_add(size=1.0)
            face = bpy.context.active_object
            face.name = f"Panel {n} LEDs"
            face.scale = (mm(PANEL), mm(PANEL), 1)
            bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
            face.location = (mm(cx), mm(cy), mm(0.2))
            uv_square(face, c / COLS, (ROWS - 1 - r) / ROWS, (c + 1) / COLS, (ROWS - r) / ROWS)
            face.data.materials.append(led)
            link(face, col_panels)
            part(face, 3)
            # the back: two HUB75 headers, a power header, four mount bosses
            zb = -PANEL_T - 4.5
            for k, dx in enumerate((-52, 52)):
                part(box(f"Panel {n} HUB75 {'in' if k == 0 else 'out'}", (20, 9, 9),
                         (cx + dx, cy + 30, zb), col_panels, plastic), 3)
            part(box(f"Panel {n} power", (14, 9, 8), (cx, cy - 55, zb), col_panels, plastic), 3)
            for sx in (-1, 1):
                for sy in (-1, 1):
                    part(cylinder(f"Panel {n} boss {sx}{sy}", 3.5, STANDOFF,
                                  (cx + sx * 60, cy + sy * 60, -PANEL_T - STANDOFF / 2),
                                  col_panels, nylon), 4)

    # ---- acrylic --------------------------------------------------------
    z0 = GAP_AIR
    part(box("Opal acrylic", (ACRYLIC, ACRYLIC, OPAL_T), (0, 0, z0 + OPAL_T / 2), col_glass, opal), 2)
    z1 = z0 + OPAL_T
    part(box("Smoked acrylic", (ACRYLIC, ACRYLIC, SMOKE_T), (0, 0, z1 + SMOKE_T / 2), col_glass, smoke), 1)

    # ---- frame -----------------------------------------------------------
    outer = FACE + 2 * FRAME_W
    zc = (Z_FRONT + Z_BACK) / 2
    off = FACE / 2 + FRAME_W / 2
    for name, at, rot in (("Rail top", (0, off, zc), 0), ("Rail bottom", (0, -off, zc), math.pi),
                          ("Rail left", (-off, 0, zc), math.pi / 2), ("Rail right", (off, 0, zc), -math.pi / 2)):
        part(frame_rail(name, outer, FRAME_W, DEPTH, at, rot, col_frame, walnut), 0)
    # the lip that holds the acrylic, a thin ring in front of it
    lip_z = Z_FRONT - LIP_T / 2
    for name, size, at in (("Lip top", (FACE + 2 * LIP, LIP, LIP_T), (0, FACE / 2 + LIP / 2, lip_z)),
                           ("Lip bottom", (FACE + 2 * LIP, LIP, LIP_T), (0, -FACE / 2 - LIP / 2, lip_z)),
                           ("Lip left", (LIP, FACE, LIP_T), (-FACE / 2 - LIP / 2, 0, lip_z)),
                           ("Lip right", (LIP, FACE, LIP_T), (FACE / 2 + LIP / 2, 0, lip_z))):
        part(box(name, size, at, col_frame, walnut), 0)
    # the design mark: the app's 7x7 lattice, one tile lit, inlaid in brass
    # on the bottom rail
    mark_y = -(FACE / 2 + FRAME_W / 2)
    for i in range(7):
        for j in range(7):
            lit = (i, j) == (4, 2)
            part(box(f"Mark {i}{j}", (1.3 if not lit else 1.9, 1.3 if not lit else 1.9, 0.6),
                     ((i - 3) * 2.4, mark_y + (j - 3) * 2.4, Z_FRONT + 0.3), col_frame, brass), 0)

    # ---- inside ----------------------------------------------------------
    part(box("Mount plate", (PLATE, PLATE, PLATE_T), (0, 0, (Z_PLATE_FRONT + Z_PLATE_BACK) / 2),
             col_inside, pvc), 5)
    zc_cav = (Z_PLATE_BACK + Z_BACK_FRONT) / 2
    psu = part(box("LRS-350-5", PSU, (0, -FACE / 2 + PSU[1] / 2 + 12, Z_PLATE_BACK - PSU[2] / 2 - 2),
                   col_inside, alu, bevel=1.0), 6)
    # its terminal block and fan grille suggested in black
    part(box("PSU terminals", (200, 14, 12), (0, -FACE / 2 + 12 + PSU[1] - 8, Z_PLATE_BACK - 8),
             col_inside, plastic), 6)
    pi_at = (-FACE / 2 + PI[0] / 2 + 30, FACE / 2 - PI[1] / 2 - 40, Z_PLATE_BACK - PI[2] / 2 - 2)
    part(box("Raspberry Pi 5", PI, pi_at, col_inside, pcb, bevel=1.0), 6)
    part(box("Triple Bonnet", BONNET, (pi_at[0] - 10, pi_at[1], pi_at[2] - PI[2] / 2 - BONNET[2] / 2 - 4),
             col_inside, pcb, bevel=0.8), 6)
    for k in range(3):
        part(box(f"Bonnet port {k + 1}", (20, 9, 9),
                 (pi_at[0] - 30, pi_at[1] + 18 - 18 * k, pi_at[2] - PI[2] / 2 - BONNET[2] - 6),
                 col_inside, plastic), 6)
    for k, (name, mat) in enumerate((("Bus bar +", brass), ("Bus bar -", brass))):
        part(box(name, BUSBAR, (FACE / 2 - BUSBAR[0] / 2 - 30, 40 - 40 * k, Z_PLATE_BACK - BUSBAR[2] / 2 - 2),
                 col_inside, mat, bevel=1.0), 6)
    for k in range(9):
        part(box(f"Fuse holder {k + 1}", FUSE,
                 (FACE / 2 - 60 - (k % 3) * 45, 120 + (k // 3) * 20 - 20, Z_PLATE_BACK - FUSE[2] / 2 - 2),
                 col_inside, plastic, bevel=0.6), 6)
    part(box("SL22 NTC", (22, 10, 6), (-60, -FACE / 2 + 24, Z_PLATE_BACK - 6), col_inside, plastic), 6)
    # the inlet through the bottom rail, switch and fuse facing down
    part(box("C14 inlet", INLET, (FACE / 2 - 90, -FACE / 2 - FRAME_W / 2, Z_BACK + 30),
             col_inside, plastic), 0)
    # back board and the French cleat on it
    part(box("Back board", (PLATE, PLATE, BACK_T), (0, 0, (Z_BACK_FRONT + Z_BACK) / 2), col_inside, pvc), 7)
    cleat = part(box("French cleat (wall)", (CLEAT_L, CLEAT_W, CLEAT_T),
                     (0, FACE / 2 - 60, Z_BACK - CLEAT_T / 2), col_inside, oak), 8)
    cleat.rotation_euler = (math.radians(45), 0, 0)
    cleat2 = part(box("French cleat (frame)", (CLEAT_L, CLEAT_W, CLEAT_T),
                      (0, FACE / 2 - 60 + CLEAT_W * 0.7, Z_BACK - CLEAT_T / 2 + 1), col_inside, oak), 7)
    cleat2.rotation_euler = (math.radians(45), 0, 0)

    # ---- wiring, suggested ----------------------------------------------
    zl = Z_PLATE_BACK - 8
    for r in range(ROWS):
        for c in range(COLS):
            cx = -half + PANEL / 2 + c * PANEL
            cy = half - PANEL / 2 - r * PANEL
            bx = FACE / 2 - BUSBAR[0] / 2 - 30
            for mat, dy, by in ((red, 3, 40), (black, -3, 0)):
                part(cable(f"Drop {r}{c} {'+' if mat is red else '-'}",
                           [(bx - 40 + c * 10, by + dy, zl), ((bx + cx) / 2, (by + cy) / 2, zl - 6),
                            (cx, cy - 55, Z_PANEL_BACK - 6)], 1.4, col_inside, mat), 6)
        # the ribbon along the row, panel out to panel in
        for c in range(COLS - 1):
            x0 = -half + PANEL / 2 + c * PANEL + 52
            x1 = x0 + PANEL - 104
            cy = half - PANEL / 2 - r * PANEL + 30
            part(cable(f"Ribbon {r}{c}", [(x0, cy, Z_PANEL_BACK - 9), ((x0 + x1) / 2, cy, Z_PANEL_BACK - 16),
                                          (x1, cy, Z_PANEL_BACK - 9)], 4.5, col_inside, ribbon, flat=True), 3)

    # ---- the room --------------------------------------------------------
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    wall = bpy.context.active_object
    wall.name = "Room wall"
    wall.scale = (4.0, 3.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    wall.rotation_euler = (math.pi / 2, 0, 0)
    wall.location = (0, mm(-Z_BACK) + 0.0015, 1.5)
    wall.data.materials.append(plaster)
    link(wall, col_room)
    bpy.ops.mesh.primitive_plane_add(size=1.0)
    floor = bpy.context.active_object
    floor.name = "Floor"
    floor.scale = (4.0, 4.0, 1)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    floor.location = (0, -1.9, 0)
    floor.data.materials.append(oak)
    link(floor, col_room)

    # ---- light and camera -------------------------------------------------
    world = bpy.data.worlds.new("World")
    sc.world = world
    if hasattr(world, "use_nodes"):
        world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.05, 0.045, 0.04, 1)
    bg.inputs[1].default_value = 0.6

    def area(name, loc, target, power, size):
        ld = bpy.data.lights.new(name, "AREA")
        ld.energy = power
        ld.size = size
        lo = bpy.data.objects.new(name, ld)
        lo.location = loc
        d = Vector(target) - Vector(loc)
        lo.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        sc.collection.objects.link(lo)
        return lo

    area("Key", (-1.6, -1.8, 2.6), (0, 0, 1.4), 110, 1.2)
    area("Fill", (1.8, -1.6, 1.6), (0, 0, 1.4), 35, 1.6)
    # for the view from behind, off unless that view asks for it
    back = area("Back light", (0.9, 1.6, 2.2), (0, 0.1, 1.4), 220, 1.4)
    back.hide_render = True

    cam_data = bpy.data.cameras.new("Camera")
    cam_data.lens = 40
    cam = bpy.data.objects.new("Camera", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    return sc, cam, parts


def aim(cam, loc, target):
    cam.location = loc
    d = Vector(target) - Vector(loc)
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()


def explode(parts, amount_mm):
    """Spread the layers apart along the wall's normal for the exploded view."""
    for o, layer in parts.values():
        o.location.z += mm(amount_mm) * (2 - layer)


def render(sc, path, samples):
    sc.render.engine = "CYCLES"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.refresh_devices()
        for d in prefs.devices:
            d.use = True
        sc.cycles.device = "GPU"
    except Exception as exc:                       # noqa: BLE001
        print("cycles gpu setup:", exc)
    sc.cycles.samples = samples
    sc.cycles.use_denoising = True
    sc.cycles.max_bounces = 12
    sc.cycles.transmission_bounces = 16
    sc.cycles.transparent_max_bounces = 16
    sc.cycles.glossy_bounces = 6
    sc.render.resolution_x = 1800
    sc.render.resolution_y = 1350
    sc.render.film_transparent = False
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
    ap.add_argument("--samples", type=int, default=160)
    ap.add_argument("--views", default="hero,front,back,exploded")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)

    sc, cam, parts = build(os.path.abspath(args.face) if args.face else "")
    centre = (0, 0, mm(WALL_H))
    views = args.views.split(",")
    wall_obj = bpy.data.objects.get("Room wall")

    if "hero" in views:
        aim(cam, (-0.72, -1.15, 1.38), (0.0, 0.0, mm(WALL_H) - 0.02))
        render(sc, os.path.join(args.out, "wall-hero.png"), args.samples)
    if "front" in views:
        cam.data.lens = 50
        aim(cam, (0, -1.3, mm(WALL_H)), centre)
        render(sc, os.path.join(args.out, "wall-front.png"), args.samples)
    if "back" in views:
        # the frame from behind, back board and room wall out of the way
        wall_obj.hide_render = True
        for name in ("Back board", "French cleat (wall)", "French cleat (frame)"):
            parts[name][0].hide_render = True
        cam.data.lens = 40
        bpy.data.objects["Back light"].hide_render = False
        aim(cam, (0.55, 0.85, 1.72), (0.0, 0.05, mm(WALL_H) - 0.02))
        render(sc, os.path.join(args.out, "wall-back.png"), args.samples)
        bpy.data.objects["Back light"].hide_render = True
        wall_obj.hide_render = False
        for name in ("Back board", "French cleat (wall)", "French cleat (frame)"):
            parts[name][0].hide_render = False
    if "exploded" in views:
        wall_obj.hide_render = True
        explode(parts, 120)
        cam.data.lens = 40
        aim(cam, (-1.05, -1.25, 1.78), (0.0, 0.08, mm(WALL_H) - 0.02))
        render(sc, os.path.join(args.out, "wall-exploded.png"), args.samples)
        explode(parts, -120)
        wall_obj.hide_render = False

    blend = os.path.join(args.out, "album-wall.blend")
    bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend))
    print("saved", blend)
    print("frame outer %.0f mm square, %.1f mm deep; LED face %.0f mm; acrylic %.0f mm"
          % (FACE + 2 * FRAME_W, DEPTH, FACE, ACRYLIC))


if __name__ == "__main__":
    main()
