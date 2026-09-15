"""The owner's actual bedroom, built rather than composited.

Reconstructed from IMG_0523: a black four-by-two cube unit against a warm
off-white wall, a chrome tulip lamp throwing a pool of light up the plaster, a
white turntable between two white bookshelf speakers, a navy puck and a white
egg speaker, records and books and a headset in the cubbies, a six-panel door
to the right, the bed coming in from the left, and a wood-look plank floor.

Everything is placed in the photographer's frame: the picture's centre is the
origin, the wall's face is at y = +0.025, +z is up and -y is toward the room.
The cube unit's top lands at z = -0.69, the same as the staged bedroom, so the
same object placement works in both.

Distances are read off the photograph against known furniture: the unit is a
1470 mm four-by-two, the door is a 762 mm slab, a record sleeve is 315 mm.
They are estimates, not a survey.
"""
import math

import bpy
from mathutils import Vector

# ------------------------------------------------------------------ the room
UNIT_W, UNIT_D, UNIT_H = 1.472, 0.390, 0.770      # a 4x2 cube unit
TOP = -0.690                                       # its top, in the photographer's frame
FLOOR = TOP - UNIT_H                               # -1.460
CEIL = FLOOR + 2.480
WALL_Y = 0.025                                     # the plaster's face
DOOR_W, DOOR_H = 0.762, 2.032


def _m(name, colour, rough=0.5, metal=0.0, sheen=0.0, coat=0.0, ior=None,
       transmission=0.0, emission=None, strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    p = m.node_tree.nodes.get("Principled BSDF")
    p.inputs["Base Color"].default_value = (*colour, 1)
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    for key, val in (("Sheen Weight", sheen), ("Coat Weight", coat),
                     ("Transmission Weight", transmission)):
        if key in p.inputs and val:
            p.inputs[key].default_value = val
    if ior is not None and "IOR" in p.inputs:
        p.inputs["IOR"].default_value = ior
    if emission is not None:
        p.inputs["Emission Color"].default_value = (*emission, 1)
        p.inputs["Emission Strength"].default_value = strength
    m.diffuse_color = (*colour, 1)
    return m


def _noise(mat, scale=60.0, detail=6.0, bump=0.0015, contrast=0.35):
    """A little dirt on a flat colour. A painted wall with no variation at all
    is the single loudest tell in an interior render."""
    nt = mat.node_tree
    p = nt.nodes.get("Principled BSDF")
    tex = nt.nodes.new("ShaderNodeTexNoise")
    tex.inputs["Scale"].default_value = scale
    tex.inputs["Detail"].default_value = detail
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].position = 0.5 - contrast / 2
    ramp.color_ramp.elements[1].position = 0.5 + contrast / 2
    nt.links.new(tex.outputs["Fac"], ramp.inputs[0])
    if bump:
        b = nt.nodes.new("ShaderNodeBump")
        b.inputs["Strength"].default_value = 0.25
        b.inputs["Distance"].default_value = bump
        nt.links.new(ramp.outputs[0], b.inputs["Height"])
        nt.links.new(b.outputs[0], p.inputs["Normal"])
    return mat


def _plank(mat):
    """Wood-look laminate: long boards running left to right, each a slightly
    different brown, with a fine grain along its length."""
    nt = mat.node_tree
    p = nt.nodes.get("Principled BSDF")
    co = nt.nodes.new("ShaderNodeTexCoord")
    brick = nt.nodes.new("ShaderNodeTexBrick")
    brick.inputs["Scale"].default_value = 1.0
    brick.inputs["Mortar Size"].default_value = 0.0016
    brick.inputs["Mortar Smooth"].default_value = 0.1
    brick.inputs["Bias"].default_value = 0.0
    brick.inputs["Brick Width"].default_value = 1.30
    brick.inputs["Row Height"].default_value = 0.128
    brick.inputs["Color1"].default_value = (0.190, 0.086, 0.036, 1)
    brick.inputs["Color2"].default_value = (0.135, 0.058, 0.024, 1)
    brick.inputs["Mortar"].default_value = (0.055, 0.026, 0.013, 1)
    nt.links.new(co.outputs["Object"], brick.inputs["Vector"])
    grain = nt.nodes.new("ShaderNodeTexNoise")
    grain.inputs["Scale"].default_value = 8.0
    grain.inputs["Detail"].default_value = 8.0
    stretch = nt.nodes.new("ShaderNodeMapping")
    stretch.inputs["Scale"].default_value = (1.0, 42.0, 1.0)
    nt.links.new(co.outputs["Object"], stretch.inputs["Vector"])
    nt.links.new(stretch.outputs[0], grain.inputs["Vector"])
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "OVERLAY"
    mix.inputs["Factor"].default_value = 0.32
    nt.links.new(brick.outputs["Color"], mix.inputs[6])
    nt.links.new(grain.outputs["Color"], mix.inputs[7])
    nt.links.new(mix.outputs[2], p.inputs["Base Color"])
    rough = nt.nodes.new("ShaderNodeMath")
    rough.operation = "MULTIPLY_ADD"
    rough.inputs[1].default_value = 0.10
    rough.inputs[2].default_value = 0.22
    nt.links.new(grain.outputs["Fac"], rough.inputs[0])
    nt.links.new(rough.outputs[0], p.inputs["Roughness"])
    return mat


class Room:
    """The bedroom, built at an offset so it lands around the object."""

    def __init__(self, offset=(0, 0, 0)):
        self.o = Vector(offset)
        self.col = bpy.data.collections.new("My room")
        bpy.context.scene.collection.children.link(self.col)
        self.lights = []
        M = self.m = {}
        M["wall"] = _noise(_m("Bedroom plaster", (0.560, 0.545, 0.510), 0.88),
                           scale=9.0, detail=8.0, bump=0.0009, contrast=0.75)
        M["ceiling"] = _m("Ceiling", (0.500, 0.492, 0.470), 0.94)
        M["floor"] = _plank(_m("Wood-look plank", (0.16, 0.075, 0.032), 0.28, coat=0.25))
        M["black"] = _noise(_m("Black-brown laminate", (0.0125, 0.0118, 0.0112), 0.42),
                            scale=340.0, detail=4.0, bump=0.0004, contrast=0.5)
        M["white"] = _m("Warm white lacquer", (0.700, 0.688, 0.660), 0.36, coat=0.35)
        M["door"] = _m("Painted door", (0.660, 0.648, 0.622), 0.52)
        M["chrome"] = _m("Polished chrome", (0.79, 0.795, 0.805), 0.075, metal=1.0)
        M["brass"] = _m("Brass knob", (0.62, 0.46, 0.20), 0.22, metal=1.0)
        M["shade"] = _m("Linen shade", (0.72, 0.66, 0.53), 0.85,
                        transmission=0.60, ior=1.05)
        M["navy"] = _m("Navy felt", (0.030, 0.038, 0.070), 0.90, sheen=0.4)
        M["grille"] = _m("Speaker grille", (0.020, 0.020, 0.021), 0.62)
        M["cone"] = _m("Driver cone", (0.72, 0.70, 0.66), 0.48)
        M["mesh"] = _m("Speaker mesh", (0.640, 0.628, 0.600), 0.72)
        M["duvet"] = _noise(_m("Grey duvet", (0.125, 0.128, 0.138), 0.94, sheen=0.7),
                            scale=90.0, detail=5.0, bump=0.004, contrast=0.5)
        M["pillow"] = _m("Pillow", (0.300, 0.296, 0.288), 0.95, sheen=0.8)
        M["throw"] = _m("Dark throw", (0.028, 0.028, 0.032), 0.95, sheen=0.5)
        M["bedframe"] = _m("Navy bed frame", (0.022, 0.026, 0.048), 0.88, sheen=0.3)
        M["vinyl"] = _m("Record", (0.014, 0.014, 0.015), 0.35)
        M["plant"] = _m("Foliage", (0.030, 0.062, 0.022), 0.74)
        M["pot"] = _m("Terracotta", (0.28, 0.115, 0.062), 0.75)
        M["headset"] = _m("Headset shell", (0.640, 0.632, 0.615), 0.44)
        M["switch"] = _m("Switch plate", (0.740, 0.732, 0.712), 0.42)
        M["gloss"] = _m("Gemini white", (0.760, 0.752, 0.735), 0.28, coat=0.6)
        M["wax"] = _m("Candle wax", (0.780, 0.760, 0.715), 0.52, transmission=0.14, ior=1.45)
        M["wick"] = _m("Wick", (0.055, 0.048, 0.040), 0.85)
        M["diffuser"] = _m("Diffuser shell", (0.755, 0.748, 0.730), 0.34, coat=0.4)
        M["mark"] = _m("Printed mark", (0.020, 0.020, 0.021), 0.60)
        self.sleeve_mats = [
            _m(f"Sleeve {i}", c, 0.80) for i, c in enumerate((
                (0.048, 0.026, 0.016), (0.115, 0.104, 0.090), (0.020, 0.019, 0.021),
                (0.082, 0.030, 0.020), (0.028, 0.036, 0.048), (0.120, 0.088, 0.048),
                (0.052, 0.052, 0.055), (0.022, 0.034, 0.026)))]
        self.book_mats = [
            _m(f"Book {i}", c, 0.86) for i, c in enumerate((
                (0.150, 0.078, 0.040), (0.038, 0.048, 0.072), (0.170, 0.152, 0.120),
                (0.072, 0.028, 0.028), (0.120, 0.117, 0.112)))]

    # -- primitives ---------------------------------------------------------
    def at(self, loc):
        return tuple(Vector(loc) + self.o)

    def box(self, name, dim, loc, mat, bev=0.002, rot=(0, 0, 0)):
        bpy.ops.mesh.primitive_cube_add(size=1, location=self.at(loc), rotation=rot)
        o = bpy.context.object
        o.name = name
        o.scale = dim
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        o.data.materials.append(mat)
        self.link(o)
        if bev:
            b = o.modifiers.new("Bevel", "BEVEL")
            b.width, b.segments = bev, 3
            o.modifiers.new("WN", "WEIGHTED_NORMAL")
        return o

    def cyl(self, name, r, h, loc, mat, axis="Z", verts=48, rot=None):
        bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=h,
                                            location=self.at(loc))
        o = bpy.context.object
        o.name = name
        if axis == "Y":
            o.rotation_euler[0] = math.pi / 2
        elif axis == "X":
            o.rotation_euler[1] = math.pi / 2
        if rot:
            o.rotation_euler = rot
        o.data.materials.append(mat)
        self.link(o)
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width, b.segments = 0.0012, 2
        return o

    def cone(self, name, r1, r2, h, loc, mat, verts=64, rot=None, smooth=True):
        bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r1, radius2=r2,
                                        depth=h, location=self.at(loc))
        o = bpy.context.object
        o.name = name
        if rot:
            o.rotation_euler = rot
        o.data.materials.append(mat)
        self.link(o)
        if smooth and verts > 12:
            bpy.ops.object.shade_smooth()
        return o

    def rod(self, name, a, b, r, mat, verts=16):
        """A cylinder between two points. The tonearm is not axis aligned."""
        a, b = Vector(a), Vector(b)
        d = b - a
        o = self.cyl(name, r, d.length, tuple((a + b) / 2), mat, verts=verts)
        o.rotation_euler = d.to_track_quat("Z", "Y").to_euler()
        return o

    def label(self, name, body, loc, size, mat, rot=(0, 0, 0), shear=0.0):
        cu = bpy.data.curves.new(name, "FONT")
        cu.body = body
        cu.size = size
        cu.align_x = "CENTER"
        cu.align_y = "CENTER"
        cu.extrude = 0.00015
        cu.shear = shear
        o = bpy.data.objects.new(name, cu)
        self.col.objects.link(o)
        o.location = self.at(loc)
        o.rotation_euler = rot
        o.data.materials.append(mat)
        return o

    def sphere(self, name, r, loc, mat, scale=(1, 1, 1)):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, radius=r,
                                             location=self.at(loc))
        o = bpy.context.object
        o.name = name
        o.scale = scale
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        bpy.ops.object.shade_smooth()
        o.data.materials.append(mat)
        self.link(o)
        return o

    def link(self, o):
        for c in list(o.users_collection):
            c.objects.unlink(o)
        self.col.objects.link(o)
        return o

    def area(self, name, loc, target, power, size, colour, size_y=None, spread=None):
        d = bpy.data.lights.new(name, "AREA")
        d.energy, d.size, d.color = power, size, colour
        if size_y:
            d.shape, d.size_y = "RECTANGLE", size_y
        if spread is not None:
            d.spread = math.radians(spread)
        o = bpy.data.objects.new(name, d)
        self.col.objects.link(o)
        o.location = self.at(loc)
        o.rotation_euler = (Vector(self.at(target)) - o.location).to_track_quat("-Z", "Y").to_euler()
        o.visible_camera = False
        self.lights.append(o)
        return o

    def point(self, name, loc, power, colour, radius=0.05):
        d = bpy.data.lights.new(name, "POINT")
        d.energy, d.color, d.shadow_soft_size = power, colour, radius
        o = bpy.data.objects.new(name, d)
        self.col.objects.link(o)
        o.location = self.at(loc)
        o.visible_camera = False
        self.lights.append(o)
        return o

    # -- the shell ----------------------------------------------------------
    def shell(self):
        M = self.m
        self.box("Wall", (7.4, 0.05, 3.4), (0.4, WALL_Y + 0.025, FLOOR + 1.70), M["wall"], 0)
        self.box("Left return wall", (0.05, 4.2, 3.4), (-2.55, -2.05, FLOOR + 1.70), M["wall"], 0)
        self.box("Floor", (8.0, 5.4, 0.04), (0.4, -2.4, FLOOR - 0.02), M["floor"], 0)
        self.box("Ceiling", (8.0, 5.4, 0.05), (0.4, -2.4, CEIL + 0.025), M["ceiling"], 0)
        self.box("Baseboard", (7.4, 0.016, 0.095), (0.4, WALL_Y - 0.008, FLOOR + 0.0475),
                 M["door"], 0.002)
        # a light switch where the photograph has one
        self.box("Switch plate", (0.077, 0.008, 0.122), (0.905, WALL_Y - 0.004, -0.245),
                 M["switch"], 0.003)
        self.box("Switch rocker", (0.026, 0.007, 0.045), (0.905, WALL_Y - 0.010, -0.245),
                 M["white"], 0.002)
        return self

    def door(self):
        M = self.m
        x0 = 1.12
        cx = x0 + DOOR_W / 2
        zc = FLOOR + DOOR_H / 2
        self.box("Door slab", (DOOR_W, 0.036, DOOR_H), (cx, WALL_Y - 0.020, zc), M["door"], 0.002)
        # six panels, as a raised-panel door reads mostly by its shadow lines
        for row, (dz, h) in enumerate(((0.63, 0.50), (0.09, 0.50), (-0.55, 0.62))):
            for dx in (-0.175, 0.175):
                self.box(f"Door panel {row}{dx:+.2f}", (0.255, 0.010, h),
                         (cx + dx, WALL_Y - 0.041, zc + dz), M["door"], 0.006)
        for name, dim, loc in (
                ("Door casing left", (0.062, 0.028, DOOR_H + 0.09),
                 (x0 - 0.031, WALL_Y - 0.014, FLOOR + (DOOR_H + 0.09) / 2)),
                ("Door casing right", (0.062, 0.028, DOOR_H + 0.09),
                 (x0 + DOOR_W + 0.031, WALL_Y - 0.014, FLOOR + (DOOR_H + 0.09) / 2)),
                ("Door head", (DOOR_W + 0.124, 0.028, 0.062),
                 (cx, WALL_Y - 0.014, FLOOR + DOOR_H + 0.031))):
            self.box(name, dim, loc, M["door"], 0.003)
        self.sphere("Door knob", 0.028, (x0 + 0.075, WALL_Y - 0.058, FLOOR + 0.965),
                    M["brass"], (1, 0.75, 1))
        self.cyl("Knob rose", 0.030, 0.010, (x0 + 0.075, WALL_Y - 0.043, FLOOR + 0.965),
                 M["brass"], axis="Y")
        return self

    # -- the cube unit and what is in it ------------------------------------
    def unit(self):
        M = self.m
        cy = WALL_Y - UNIT_D / 2
        T = 0.038                                     # a cube unit's own board
        z0 = FLOOR
        self.box("Unit top", (UNIT_W, UNIT_D, T), (0, cy, TOP - T / 2), M["black"], 0.0016)
        self.box("Unit bottom", (UNIT_W, UNIT_D, T), (0, cy, z0 + T / 2), M["black"], 0.0016)
        self.box("Unit mid shelf", (UNIT_W, UNIT_D, T), (0, cy, z0 + UNIT_H / 2), M["black"], 0.0016)
        for x in (-UNIT_W / 2 + T / 2, UNIT_W / 2 - T / 2, -0.368, 0.0, 0.368):
            self.box(f"Unit upright {x:+.3f}", (T, UNIT_D, UNIT_H - 2 * T),
                     (x, cy, z0 + UNIT_H / 2), M["black"], 0.0016)
        self.box("Unit back", (UNIT_W, 0.005, UNIT_H), (0, WALL_Y - 0.004, z0 + UNIT_H / 2),
                 M["black"], 0)

        cell = (UNIT_W - 6 * T) / 4                   # about 0.311
        cols = [-0.552, -0.184, 0.184, 0.552]
        z_low = z0 + T + (UNIT_H / 2 - 1.5 * T) / 2
        z_up = z0 + UNIT_H / 2 + T / 2 + (UNIT_H / 2 - 1.5 * T) / 2

        # bottom left two cubbies: records on their edges
        for c in (0, 1):
            x0 = cols[c] - cell / 2 + 0.014
            for i in range(38):
                x = x0 + i * 0.0072
                self.box(f"Sleeve {c}-{i}", (0.0056, 0.312, 0.312),
                         (x, cy - 0.030, z_low + 0.010),
                         self.sleeve_mats[(i * 3 + c) % len(self.sleeve_mats)], 0.0004)
        # bottom right: books, leaning
        x0 = cols[3] - cell / 2 + 0.030
        for i in range(9):
            h = 0.215 + 0.018 * ((i * 5) % 4)
            self.box(f"Book {i}", (0.026, 0.150, h), (x0 + i * 0.030, cy - 0.070,
                                                      z_low - 0.145 + h / 2 + 0.010),
                     self.book_mats[i % len(self.book_mats)], 0.0015,
                     rot=(0, math.radians(3 if i > 6 else 0), 0))
        # bottom third: a dark storage box
        self.box("Storage box", (0.290, 0.330, 0.270), (cols[2], cy - 0.020, z_low + 0.010),
                 M["black"], 0.004)

        # top left cubbies: a shelf of small things and a plant
        for i, (dx, r, h) in enumerate(((-0.10, 0.026, 0.052), (-0.03, 0.020, 0.040),
                                        (0.05, 0.030, 0.058), (0.12, 0.018, 0.036))):
            self.cyl(f"Figure {i}", r, h, (cols[0] + dx, cy - 0.090, z_up - 0.115 + h / 2),
                     self.sleeve_mats[(i * 2) % len(self.sleeve_mats)])
        self.cyl("Plant pot", 0.058, 0.086, (cols[1] - 0.045, cy - 0.070, z_up - 0.115 + 0.043),
                 M["pot"], verts=32)
        for i in range(26):
            a = i * 2.399963
            rr = 0.020 + 0.052 * (i % 5) / 4
            self.sphere(f"Foliage {i}", 0.016 + 0.008 * ((i * 3) % 4) / 3,
                        (cols[1] - 0.045 + rr * math.cos(a), cy - 0.072 + 0.030 * math.sin(a),
                         z_up - 0.052 + 0.052 * (i % 7) / 6),
                        M["plant"], (1.0, 0.5, 0.7))
        self.cyl("Plant pot 2", 0.046, 0.070, (cols[1] + 0.085, cy - 0.100, z_up - 0.115 + 0.035),
                 M["pot"], verts=32)
        for i in range(18):
            a = i * 2.399963
            rr = 0.014 + 0.038 * (i % 4) / 3
            self.sphere(f"Foliage b {i}", 0.013 + 0.007 * ((i * 5) % 3) / 2,
                        (cols[1] + 0.085 + rr * math.cos(a), cy - 0.100 + 0.024 * math.sin(a),
                         z_up - 0.056 + 0.044 * (i % 6) / 5),
                        M["plant"], (1.0, 0.5, 0.7))
        # top third: a headset on a stand
        self.box("Headset stand", (0.150, 0.110, 0.014), (cols[2], cy - 0.060, z_up - 0.108),
                 M["black"], 0.003)
        self.sphere("Headset body", 0.086, (cols[2], cy - 0.060, z_up - 0.045),
                    M["headset"], (1.0, 0.72, 0.62))
        self.box("Headset facia", (0.150, 0.020, 0.086), (cols[2], cy - 0.128, z_up - 0.045),
                 M["grille"], 0.012)
        self.box("Headset strap", (0.176, 0.030, 0.020), (cols[2], cy - 0.060, z_up + 0.008),
                 M["headset"], 0.006)
        for dx in (-0.098, 0.098):
            self.box(f"Headset wing {dx:+.3f}", (0.052, 0.070, 0.076),
                     (cols[2] + dx, cy - 0.060, z_up - 0.048), M["headset"], 0.010)
        # top right: cables and a dark bin
        self.box("Cable bin", (0.240, 0.300, 0.180), (cols[3], cy - 0.030, z_up - 0.115 + 0.090),
                 M["black"], 0.004)
        return self

    # -- what stands on top -------------------------------------------------
    def deck(self):
        """Left to right: a chrome tulip lamp, a white barn candle, a Gemini
        speaker, the Gemini TT-900 turntable, the second speaker, an air
        diffuser.

        The first pass had a 400 mm plinth, which is wider than the real one and
        wide enough to pass through both speaker cabinets. The TT-900 is
        360 x 300 mm, and everything on the top is spaced off it: 62 mm of air
        to the left speaker and 57 mm to the right.
        """
        M = self.m
        cy = WALL_Y - 0.200
        top = TOP

        # the chrome tulip lamp
        lx = -0.560
        self.cone("Lamp foot", 0.088, 0.030, 0.026, (lx, cy - 0.010, top + 0.013), M["chrome"])
        self.cone("Lamp stem", 0.030, 0.013, 0.230, (lx, cy - 0.010, top + 0.141), M["chrome"])
        self.cyl("Lamp neck", 0.011, 0.070, (lx, cy - 0.010, top + 0.290), M["chrome"], verts=24)
        shade = self.cone("Linen shade", 0.118, 0.086, 0.170,
                          (lx, cy - 0.010, top + 0.395), M["shade"])
        shade.modifiers.new("Solidify", "SOLIDIFY").thickness = 0.0015
        self.point("Bulb", (lx, cy - 0.010, top + 0.400), 26.0, (1.0, 0.735, 0.470), 0.035)

        # a white barn candle: a wide short pillar, burned down a little
        kx = -0.408
        self.cyl("Barn candle", 0.045, 0.082, (kx, cy + 0.010, top + 0.041), M["wax"], verts=48)
        self.cyl("Candle well", 0.037, 0.006, (kx, cy + 0.010, top + 0.080), M["wax"], verts=48)
        self.cyl("Wick", 0.0016, 0.010, (kx, cy + 0.010, top + 0.083), M["wick"], verts=8)

        # the two Gemini bookshelf speakers
        SP_W, SP_D, SP_H = 0.105, 0.150, 0.175
        for i, sx in enumerate((-0.285, 0.300)):
            zc = top + SP_H / 2
            self.box(f"Speaker {i}", (SP_W, SP_D, SP_H), (sx, cy - 0.010, zc), M["gloss"], 0.003)
            face = cy - 0.010 - SP_D / 2
            # the faceted baffle: a big hexagonal well round the woofer and a
            # small one round the tweeter, which is what these actually look like
            self.cone(f"Woofer well {i}", 0.041, 0.032, 0.009,
                      (sx, face + 0.0045, top + 0.062), M["gloss"], verts=6,
                      rot=(math.pi / 2, math.radians(30), 0), smooth=False)
            self.cone(f"Tweeter well {i}", 0.021, 0.016, 0.007,
                      (sx, face + 0.0035, top + 0.140), M["gloss"], verts=6,
                      rot=(math.pi / 2, math.radians(30), 0), smooth=False)
            self.cyl(f"Woofer surround {i}", 0.030, 0.008, (sx, face - 0.001, top + 0.062),
                     M["grille"], axis="Y")
            self.cone(f"Woofer cone {i}", 0.024, 0.012, 0.010,
                      (sx, face - 0.005, top + 0.062), M["cone"], verts=48,
                      rot=(-math.pi / 2, 0, 0))
            self.sphere(f"Dust cap {i}", 0.0095, (sx, face - 0.008, top + 0.062),
                        M["cone"], (1, 0.55, 1))
            self.cyl(f"Tweeter face {i}", 0.014, 0.005, (sx, face - 0.001, top + 0.140),
                     M["grille"], axis="Y")
            self.sphere(f"Tweeter dome {i}", 0.0065, (sx, face - 0.004, top + 0.140),
                        M["grille"], (1, 0.6, 1))
            self.label(f"Speaker mark {i}", "gemini",
                       (sx - 0.028, face - 0.0012, top + 0.016), 0.0062, M["mark"],
                       rot=(math.pi / 2, 0, 0), shear=0.18)

        # the Gemini TT-900: 360 x 300, a 235 mm platter, the arm at the back
        # right, three controls at the front right, four black feet
        tx = 0.010
        TT_W, TT_D, TT_H, FOOT = 0.360, 0.300, 0.058, 0.020
        base = top + FOOT
        deck_z = base + TT_H
        for dx in (-0.150, 0.150):
            for dy in (-0.120, 0.120):
                self.cyl(f"TT foot {dx:+.2f}{dy:+.2f}", 0.012, FOOT,
                         (tx + dx, cy + dy, top + FOOT / 2), M["grille"], verts=24)
        self.box("TT plinth", (TT_W, TT_D, TT_H), (tx, cy, base + TT_H / 2),
                 M["gloss"], 0.005)
        px, py = tx - 0.050, cy - 0.008
        # a shadow gap round the platter: white on white, the disc read as part
        # of the plinth in the first render
        self.cyl("Platter well", 0.1215, 0.010, (px, py, deck_z - 0.002), M["grille"], verts=96)
        self.cyl("Platter", 0.1175, 0.016, (px, py, deck_z + 0.005), M["gloss"], verts=96)
        self.label("Platter mark", "gemini", (px, py, deck_z + 0.0135), 0.058,
                   M["mark"], shear=0.22)
        self.cyl("Spindle", 0.0035, 0.014, (px, py, deck_z + 0.014), M["chrome"], verts=16)
        # the arm: a compact pivot at the back right and a nearly flat tube
        ax, ay = tx + 0.132, cy + 0.086
        self.cyl("Arm post", 0.015, 0.030, (ax, ay, deck_z + 0.015), M["gloss"], verts=32)
        self.cyl("Arm gimbal", 0.017, 0.028, (ax, ay, deck_z + 0.036), M["chrome"],
                 axis="Y", verts=32)
        self.cyl("Counterweight", 0.019, 0.030, (ax, ay + 0.036, deck_z + 0.036),
                 M["grille"], axis="Y", verts=32)
        self.rod("Tonearm", (ax - 0.012, ay - 0.014, deck_z + 0.034),
                 (tx - 0.008, cy - 0.076, deck_z + 0.024), 0.0035, M["chrome"])
        self.box("Headshell", (0.022, 0.026, 0.012), (tx - 0.012, cy - 0.084, deck_z + 0.021),
                 M["gloss"], 0.002)
        self.cyl("Arm rest post", 0.007, 0.038, (tx + 0.118, cy - 0.040, deck_z + 0.019),
                 M["gloss"], verts=16)
        self.box("Arm rest", (0.026, 0.010, 0.007), (tx + 0.108, cy - 0.040, deck_z + 0.036),
                 M["gloss"], 0.002)
        for k, dx in enumerate((0.058, 0.098, 0.138)):
            self.cyl(f"Control {k}", 0.0115, 0.017, (tx + dx, cy - 0.108, deck_z + 0.0085),
                     M["gloss"], verts=32)
        self.label("TT mark", "gemini", (tx - 0.118, cy - 0.118, deck_z + 0.0005),
                   0.010, M["mark"], shear=0.18)

        # the air diffuser: a white shell on a dark base, with its vent on top
        dx_ = 0.555
        self.cyl("Diffuser base", 0.050, 0.018, (dx_, cy + 0.020, top + 0.009),
                 M["grille"], verts=48)
        self.sphere("Diffuser shell", 0.060, (dx_, cy + 0.020, top + 0.074),
                    M["diffuser"], (0.94, 0.94, 1.10))
        self.cyl("Diffuser vent", 0.014, 0.006, (dx_, cy + 0.020, top + 0.140),
                 M["grille"], verts=32)
        return self

    # -- the bed, coming in from the left ------------------------------------
    def bed(self):
        M = self.m
        bx, by = -1.760, -0.980
        self.box("Bed frame", (1.42, 2.02, 0.280), (bx, by, FLOOR + 0.140), M["bedframe"], 0.008)
        self.box("Mattress", (1.36, 1.96, 0.240), (bx, by, FLOOR + 0.400), M["duvet"], 0.030)
        self.box("Duvet", (1.40, 1.52, 0.110), (bx, by - 0.180, FLOOR + 0.560), M["duvet"], 0.055)
        self.box("Pillow", (0.62, 0.36, 0.130), (bx - 0.28, by + 0.760, FLOOR + 0.580),
                 M["pillow"], 0.060, rot=(0, 0, math.radians(-6)))
        self.box("Pillow 2", (0.60, 0.34, 0.120), (bx + 0.30, by + 0.780, FLOOR + 0.575),
                 M["pillow"], 0.055, rot=(0, 0, math.radians(4)))
        self.box("Dark throw", (0.86, 0.46, 0.150), (bx + 0.10, by + 0.840, FLOOR + 0.615),
                 M["throw"], 0.070, rot=(0, 0, math.radians(9)))
        self.box("Headboard", (1.42, 0.070, 0.520), (bx, by + 1.045, FLOOR + 0.560),
                 M["bedframe"], 0.010)
        return self

    # -- light --------------------------------------------------------------
    def light(self, world_strength=0.012):
        """One practical and a little bounce. The photograph is a lamp on the
        left throwing a pool up the plaster and almost nothing else, so the
        render is built the same way rather than lit like a showroom."""
        M = self.m
        # a soft ceiling bounce standing in for the room's own light
        self.area("Ceiling bounce", (0.1, -1.5, CEIL - 0.06), (0.1, -0.9, FLOOR),
                  16.0, 2.4, (1.0, 0.86, 0.70), size_y=2.0)
        # the doorway, cool, so the right side does not go dead
        self.area("Doorway spill", (2.6, -1.2, FLOOR + 1.30), (0.9, -0.2, FLOOR + 1.1),
                  9.0, 1.1, (0.72, 0.78, 0.95), size_y=1.9)
        # a low warm fill from the floor, which the plank floor really does
        self.area("Floor bounce", (0.0, -1.10, FLOOR + 0.05), (0.0, -0.2, TOP + 0.4),
                  7.0, 2.2, (1.0, 0.72, 0.44), size_y=1.4)
        world = bpy.data.worlds.new("Night room")
        world.use_nodes = True
        bg = world.node_tree.nodes["Background"]
        bg.inputs[0].default_value = (0.34, 0.36, 0.44, 1)
        bg.inputs[1].default_value = world_strength
        bpy.context.scene.world = world
        return self

    def build(self):
        return self.shell().door().unit().deck().bed().light()

    # -- cameras ------------------------------------------------------------
    def camera(self, name, pos, target, lens=40.0, fstop=None, focus=None):
        d = bpy.data.cameras.new(name)
        d.lens = lens
        d.clip_start, d.clip_end = 0.005, 300
        if fstop:
            d.dof.use_dof = True
            d.dof.aperture_fstop = fstop
            d.dof.focus_distance = (Vector(self.at(focus or target)) - Vector(self.at(pos))).length
        o = bpy.data.objects.new(name, d)
        self.col.objects.link(o)
        o.location = self.at(pos)
        o.rotation_euler = (Vector(self.at(target)) - o.location).to_track_quat("-Z", "Y").to_euler()
        return o
