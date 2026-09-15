"""A room built for one object and one record, four times.

The bedroom is where these actually go. This is the other picture: a small
purpose-built space, art directed to the album the panel is showing, so the
object and the record are lit by the same idea.

    submerged   Obsidian, and Billie Eilish's HIT ME HARD AND SOFT. A drowned
                blue room, one cold slot of light from high up, a wet floor.
    prima       Alabaster, and ADELA's PRIMA. High key white, glossy floor, one
                magenta rim off the right, everything bright and hard edged.
    tintype     Heartwood, and Ethel Cain's WILLOUGHBY TUCKER. Aged limewash, a
                wide oak floor, one low warm shaft through a window off frame,
                and enough dust in the air to see it.
    grey        Argent, and Tate McRae's SO CLOSE TO WHAT. A cool grey room
                under one very large soft toplight, satin floor, no drama.

Same frame as everywhere else: the picture's centre is the origin, the wall's
face is y = +0.025, +z is up and -y is toward the camera.
"""
import math

import bpy
from mathutils import Vector

from my_room import _m, _noise, _plank

FLOOR = -1.460
CEIL = FLOOR + 2.700
WALL_Y = 0.025          # default face of the wall, overridden per object
PAD = 0.016             # the wall pads the object stands off on
RETURN_X = 1.35         # close enough that a corner reads as depth in a wide shot

# Every number here is a decision, so they are all in one place.
LOOKS = {
    "submerged": {
        "wall": ((0.0125, 0.0165, 0.0245), 0.86, 9.0, 0.0011),
        "side": (0.0075, 0.0100, 0.0155),
        "floor": ("polished", (0.0090, 0.0115, 0.0165), 0.085),
        "world": ((0.030, 0.055, 0.095), 0.016),
        "lights": [
            # one cold slot from high and left, the way light falls through water
            ("Slot", (-0.62, -0.34, 1.46), (-0.42, 0.0, -1.05), 300.0, 0.14, (0.60, 0.80, 1.00), 2.60),
            ("Caustic", (1.02, -1.05, 1.18), (0.42, 0.0, -0.86), 96.0, 0.16, (0.55, 0.78, 1.00), 1.40),
            ("Deep fill", (1.90, -2.10, -0.75), (0.0, 0.0, -0.30), 34.0, 1.60, (0.24, 0.42, 0.70), None),
            ("Floor sheen", (0.0, -1.30, FLOOR + 0.04), (0.0, 0.0, -0.20), 22.0, 2.00, (0.36, 0.58, 0.90), 1.20),
        ],
        "bench": ((1.55, 0.42, 0.26), (0.95, -0.62, FLOOR + 0.13), (0.020, 0.024, 0.032)),
        "volume": 0.0,
    },
    "prima": {
        "wall": ((0.700, 0.688, 0.680), 0.80, 14.0, 0.0006),
        "side": (0.640, 0.628, 0.622),
        "floor": ("gloss", (0.720, 0.706, 0.700), 0.055),
        "world": ((0.72, 0.74, 0.80), 0.55),
        "lights": [
            ("Key", (-1.05, -0.72, 1.42), (-0.30, 0.0, -0.95), 300.0, 1.05, (1.00, 0.98, 0.96), 2.40),
            ("Bounce", (1.70, -1.55, -0.35), (0.0, 0.0, -0.10), 90.0, 1.80, (1.00, 0.97, 0.95), None),
            # the cover's magenta, kept to a rim so the room stays white
            ("Magenta rim", (1.55, 0.55, 0.72), (0.10, 0.0, 0.02), 55.0, 0.55, (1.00, 0.16, 0.46), None),
        ],
        "bench": None,
        "plinth": ((0.34, 0.34, 0.44), (0.92, -0.55, FLOOR + 0.22), (0.760, 0.748, 0.742)),
        "volume": 0.0,
    },
    "tintype": {
        "wall": ((0.240, 0.208, 0.168), 0.92, 6.0, 0.0016),
        "side": (0.180, 0.152, 0.120),
        "floor": ("oak", (0.16, 0.075, 0.032), 0.30),
        "world": ((0.16, 0.13, 0.10), 0.055),
        "lights": [
            # a low window off frame right, late in the day
            ("Window", (1.72, -0.82, 0.46), (-0.42, 0.0, -0.62), 260.0, 0.55, (1.00, 0.72, 0.42), 1.70),
            ("Warm bounce", (-1.60, -1.50, -0.80), (0.0, 0.0, -0.20), 26.0, 1.70, (1.00, 0.66, 0.38), None),
            ("Ceiling wash", (0.10, -1.20, CEIL - 0.10), (0.10, -0.30, FLOOR), 16.0, 1.90, (1.00, 0.80, 0.58), 1.50),
        ],
        "bench": ((1.20, 0.36, 0.42), (-1.05, -0.58, FLOOR + 0.21), (0.055, 0.028, 0.014)),
        "volume": 0.010,
    },
    "grey": {
        "wall": ((0.285, 0.292, 0.305), 0.84, 11.0, 0.0007),
        "side": (0.255, 0.262, 0.275),
        "floor": ("satin", (0.235, 0.240, 0.250), 0.16),
        "world": ((0.45, 0.48, 0.55), 0.045),
        "lights": [
            # one very large soft toplight, the way a dance floor is lit
            ("Toplight", (0.05, -0.30, CEIL - 0.12), (0.02, -0.10, -1.25), 300.0, 1.55, (0.90, 0.94, 1.00), 0.85),
            ("Cool fill", (-1.85, -2.00, -0.25), (0.0, 0.0, -0.10), 22.0, 1.60, (0.80, 0.86, 1.00), None),
            ("Edge", (1.95, 0.35, 0.55), (0.15, 0.0, 0.05), 60.0, 0.50, (1.00, 0.97, 0.92), None),
        ],
        "bench": None,
        "volume": 0.0,
    },
}


def _floor_material(kind, colour, rough):
    m = _m(f"Floor {kind}", colour, rough, coat=0.35 if kind in ("gloss", "polished") else 0.10)
    if kind == "oak":
        return _plank(m)
    # a floor with one roughness everywhere is the loudest tell in an interior:
    # real polished concrete and resin both mottle
    return _noise(m, scale=3.2, detail=8.0, bump=0.0004, contrast=0.55)


class Room:
    """One of the four, built around the object at the origin."""

    def __init__(self, look="grey", back=0.0):
        # The object's own depth decides where the wall goes. A 240 mm deep box
        # and a 40 mm thin frame cannot share one wall plane: put the wall at a
        # fixed y and the box's rear-facing halo ends up buried inside it, which
        # is exactly why the first pass had no glow behind anything.
        self.look = LOOKS[look]
        self.name = look
        self.wall_y = max(WALL_Y, back + PAD)
        self.col = bpy.data.collections.new(f"Showroom {look}")
        bpy.context.scene.collection.children.link(self.col)
        self.lights = []
        w, wr, ws, wb = self.look["wall"]
        self.m = {
            "wall": _noise(_m(f"{look} plaster", w, wr), scale=ws, detail=8.0,
                           bump=wb, contrast=0.7),
            "side": _m(f"{look} return", self.look["side"], 0.88),
            "floor": _floor_material(*self.look["floor"]),
            "trim": _m(f"{look} trim", tuple(c * 0.55 for c in w), 0.55),
        }

    # -- primitives ---------------------------------------------------------
    def box(self, name, dim, loc, mat, bev=0.003):
        bpy.ops.mesh.primitive_cube_add(size=1, location=loc)
        o = bpy.context.object
        o.name = name
        o.scale = dim
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        o.data.materials.append(mat)
        for c in list(o.users_collection):
            c.objects.unlink(o)
        self.col.objects.link(o)
        if bev:
            b = o.modifiers.new("Bevel", "BEVEL")
            b.width, b.segments = bev, 3
            o.modifiers.new("WN", "WEIGHTED_NORMAL")
        return o

    def area(self, name, loc, target, power, size, colour, size_y=None):
        d = bpy.data.lights.new(name, "AREA")
        d.energy, d.size, d.color = power, size, colour
        if size_y:
            d.shape, d.size_y = "RECTANGLE", size_y
        o = bpy.data.objects.new(name, d)
        self.col.objects.link(o)
        o.location = loc
        o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        o.visible_camera = False
        self.lights.append(o)
        return o

    # -- the set ------------------------------------------------------------
    def build(self):
        M = self.m
        wy = self.wall_y
        self.box("Wall", (7.0, 0.06, 3.6), (0.0, wy + 0.03, FLOOR + 1.80), M["wall"], 0)
        self.box("Return left", (0.06, 5.0, 3.6), (-RETURN_X, wy - 2.45, FLOOR + 1.80),
                 M["side"], 0)
        self.box("Return right", (0.06, 5.0, 3.6), (RETURN_X, wy - 2.45, FLOOR + 1.80),
                 M["side"], 0)
        self.box("Floor", (7.0, 5.2, 0.06), (0.0, wy - 2.50, FLOOR - 0.03), M["floor"], 0)
        self.box("Ceiling", (7.0, 5.2, 0.06), (0.0, wy - 2.50, CEIL + 0.03), M["side"], 0)
        # a shadow gap where the wall meets the floor, which is what a gallery has
        # instead of a skirting board
        self.box("Shadow gap", (7.0, 0.022, 0.030), (0.0, wy - 0.012, FLOOR + 0.015),
                 M["trim"], 0)

        dy = wy - WALL_Y
        bench = self.look.get("bench")
        if bench:
            dim, loc, colour = bench
            loc = (loc[0], loc[1] + dy, loc[2])
            self.box("Bench", dim, loc, _m(f"{self.name} bench", colour, 0.62), 0.006)
        plinth = self.look.get("plinth")
        if plinth:
            dim, loc, colour = plinth
            loc = (loc[0], loc[1] + dy, loc[2])
            self.box("Plinth", dim, loc, _m(f"{self.name} plinth", colour, 0.42, coat=0.3), 0.004)

        for name, loc, tgt, *rest in self.look["lights"]:
            self.area(name, (loc[0], loc[1] + dy, loc[2]),
                      (tgt[0], tgt[1] + dy, tgt[2]), *rest)

        world = bpy.data.worlds.new(f"Showroom {self.name}")
        world.use_nodes = True
        bg = world.node_tree.nodes["Background"]
        colour, strength = self.look["world"]
        bg.inputs[0].default_value = (*colour, 1)
        bg.inputs[1].default_value = strength
        bpy.context.scene.world = world

        # dust in the shaft, only where the direction calls for it
        if self.look.get("volume"):
            bpy.ops.mesh.primitive_cube_add(size=1, location=(0.0, wy - 1.925, FLOOR + 1.35))
            v = bpy.context.object
            v.name = "Air"
            v.scale = (4.4, 4.6, 2.6)
            bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
            mat = bpy.data.materials.new("Dust")
            mat.use_nodes = True
            nt = mat.node_tree
            for n in list(nt.nodes):
                if n.type != "OUTPUT_MATERIAL":
                    nt.nodes.remove(n)
            out = nt.nodes["Material Output"]
            sc = nt.nodes.new("ShaderNodeVolumePrincipled")
            sc.inputs["Density"].default_value = self.look["volume"]
            sc.inputs["Anisotropy"].default_value = 0.55
            sc.inputs["Color"].default_value = (1.0, 0.86, 0.68, 1)
            nt.links.new(sc.outputs[0], out.inputs["Volume"])
            v.data.materials.append(mat)
            v.visible_shadow = False
            for c in list(v.users_collection):
                c.objects.unlink(v)
            self.col.objects.link(v)
        return self

    def camera(self, name, pos, target, lens=50.0, fstop=None, focus=None):
        d = bpy.data.cameras.new(name)
        d.lens = lens
        d.clip_start, d.clip_end = 0.005, 300
        if fstop:
            d.dof.use_dof = True
            d.dof.aperture_fstop = fstop
            d.dof.focus_distance = (Vector(focus or target) - Vector(pos)).length
        o = bpy.data.objects.new(name, d)
        self.col.objects.link(o)
        o.location = pos
        o.rotation_euler = (Vector(target) - o.location).to_track_quat("-Z", "Y").to_euler()
        return o
