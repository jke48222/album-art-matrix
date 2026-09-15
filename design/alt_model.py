"""Four objects, not four finishes.

Each of these is a different thing to have on a wall, with its own silhouette,
its own material logic and its own answer to where your hand goes to switch it
on. Nothing is shared but the nine panels and the box of electronics that has
to hide somewhere.

    sleeve   an oversized record jacket, open along its top edge. The mains
             module sits in that opening: you switch it on by reaching into
             the sleeve, the way you would lift out a record.
    lean     it does not hang. A heavy slab tipped back eight degrees in a
             solid foot, standing on a sideboard. The switch is in the foot's
             right end, under your hand.
    system   two pieces. The picture becomes a thin plate because the machine
             moved out of it into a separate module below, which carries the
             supply, the Pi and a real front-panel switch. After Rams' 606:
             a small number of components, hung on a wall, rearrangeable.
    splay    a deep funnel, wide at the wall and narrow at the picture, so the
             artwork's own light floods four pale sloping walls. Off, a
             faceted block. The switch is under the bottom edge.

Verified numbers come from wall_model.py. What is new is marked here the same
way: VERIFIED / LISTING / TYPICAL / DESIGN.

    /Applications/Blender.app/Contents/MacOS/Blender --background \
        --python design/alt_model.py -- --design splay --out design/renders \
        --face design/face192.png
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

# ============================================================== new numbers
FACE = W.FACE                  # 480: three panels of 160
INLET = W.INLET                # LISTING  Antrader C14 with switch and fuse
INLET_CUT = W.INLET_CUTOUT     # TYPICAL  47 x 27.5 panel cutout
ACR_T = W.ACR_T
AIR = 6.7                      # DESIGN   glass over the LEDs, as wall_model has
HALO_SEGS, HALO_SUB = 3, 3     # DESIGN   three colour zones an edge, split
                               #          three ways so the wall gets a wash
CAVITY = 63.5                  # LISTING  1 x 3 on edge: what the supply, the
                               #          bars and the Pi stack need
BACK_T = W.BACK_T              # LISTING  1/4 in ply

Z_PANEL_BACK = -W.PANEL_T                          # -14.5
Z_STEEL_FRONT = Z_PANEL_BACK - W.MAG_FOOT_H        # -25.1
Z_STEEL_BACK = Z_STEEL_FRONT - W.STEEL_T
Z_PLY_BACK = Z_STEEL_BACK - W.PLY_T                # -38.56

CLOTH = {"charcoal": (0.055, 0.055, 0.058), "oatmeal": (0.360, 0.320, 0.258),
         "oxblood": (0.115, 0.028, 0.030), "forest": (0.028, 0.070, 0.052),
         "ink": (0.021, 0.030, 0.062)}


# ================================================================= materials

def cloth_material(name, base):
    """Wool: two crossed bands for the weave, noise over it for the fuzz, and
    a ramp so the threads darken where they dip. Without the ramp it reads as
    paint with a bumpy normal."""
    m, nt, b = W.principled(f"Cloth {name}")
    b.inputs["Roughness"].default_value = 0.95
    if "Sheen Weight" in b.inputs:
        b.inputs["Sheen Weight"].default_value = 0.35
        b.inputs["Sheen Roughness"].default_value = 0.4
    b.inputs["Specular IOR Level"].default_value = 0.18
    tex = nt.nodes.new("ShaderNodeTexCoord")
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
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*[c * 0.62 for c in base], 1.0)
    ramp.color_ramp.elements[1].color = (*[min(1.0, c * 1.22) for c in base], 1.0)
    nt.links.new(mixw.outputs[2], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
    return m


def board_material(name, base, rough=0.86):
    """Painted or papered sheet: flat, with just enough tooth to catch a
    raking light. A perfectly smooth matte surface renders as cardboard."""
    m, nt, b = W.principled(name)
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Specular IOR Level"].default_value = 0.32
    tex = nt.nodes.new("ShaderNodeTexCoord")
    n = nt.nodes.new("ShaderNodeTexNoise")
    n.inputs["Scale"].default_value = 620.0
    n.inputs["Detail"].default_value = 3.0
    nt.links.new(tex.outputs["Object"], n.inputs["Vector"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.14
    nt.links.new(n.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m


def leather_material(name="Saddle leather", base=(0.30, 0.15, 0.06)):
    """Vegetable-tanned leather: warm, a little sheen, fine grain in the
    normal, and the colour darkened where the grain dips."""
    m, nt, b = W.principled(name)
    b.inputs["Roughness"].default_value = 0.52
    b.inputs["Specular IOR Level"].default_value = 0.40
    if "Sheen Weight" in b.inputs:
        b.inputs["Sheen Weight"].default_value = 0.15
    tex = nt.nodes.new("ShaderNodeTexCoord")
    n = nt.nodes.new("ShaderNodeTexNoise")
    n.inputs["Scale"].default_value = 420.0
    n.inputs["Detail"].default_value = 5.0
    nt.links.new(tex.outputs["Object"], n.inputs["Vector"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.30
    bump.inputs["Distance"].default_value = 0.5
    nt.links.new(n.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*[c * 0.70 for c in base], 1.0)
    ramp.color_ramp.elements[1].color = (*[min(1.0, c * 1.15) for c in base], 1.0)
    nt.links.new(n.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
    return m


def walnut():
    """The first design's oiled black walnut, borrowed so it is the same
    wood in both files."""
    try:
        import wall_model_walnut as WN
        return WN.walnut_material()
    except Exception:                                    # noqa: BLE001
        return board_material("Walnut", (0.045, 0.024, 0.014), 0.55)


def rounded_rect(w, h, r, n=10):
    """Corners as arcs, n points each, counter-clockwise from the right."""
    hw, hh = w / 2, h / 2
    pts = []
    for cx, cy, a0 in ((hw - r, hh - r, 0.0), (-hw + r, hh - r, 90.0),
                       (-hw + r, -hh + r, 180.0), (hw - r, -hh + r, 270.0)):
        for i in range(n + 1):
            a = math.radians(a0 + 90.0 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def chamfered_rect(w, h, c):
    hw, hh = w / 2, h / 2
    return [(hw, hh - c), (hw - c, hh), (-hw + c, hh), (-hw, hh - c),
            (-hw, -hh + c), (-hw + c, -hh), (hw - c, -hh), (hw, -hh + c)]


def slab(name, outline, t, z, col, mat):
    """A flat outline given thickness, centred on z. The soft and chamfered
    bodies are outlines, and no primitive makes those."""
    me = bpy.data.meshes.new(name)
    me.from_pydata([(mm(x), mm(y), mm(z)) for x, y in outline], [], [list(range(len(outline)))])
    me.update()
    o = bpy.data.objects.new(name, me)
    if mat:
        me.materials.append(mat)
    sd = o.modifiers.new("Solidify", "SOLIDIFY")
    sd.thickness, sd.offset = mm(t), 0.0
    link(o, col)
    return o


def halo_colours(face_png):
    """Twelve zones: three to an edge, one to each panel, each the average of
    the artwork's own outer strip lifted and saturated. An average is duller
    than the picture it came from, and a dull halo reads as a fault."""
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
        mx = max(r, g, b, 1e-6)
        lift = min(1.0, 0.35 + mx) / mx
        mid = (r + g + b) / 3.0
        return tuple(min(1.0, mid + (c - mid) * 1.45) * lift for c in (r, g, b))

    out = []
    third = [(0, w // 3), (w // 3, 2 * w // 3), (2 * w // 3, w)]
    for a, b_ in third:
        out.append(avg(a, b_, 0, d))
    for a, b_ in third:
        out.append(avg(w - d, w, a, b_))
    for a, b_ in reversed(third):
        out.append(avg(a, b_, h - d, h))
    for a, b_ in reversed(third):
        out.append(avg(0, d, a, b_))
    bpy.data.images.remove(img)
    return out


def poly(name, verts, col, mat, thickness=0.0):
    """A flat face from four corners in mm, optionally given thickness. The
    splay's sloping walls are trapezoids and no primitive makes those."""
    me = bpy.data.meshes.new(name)
    me.from_pydata([(mm(v[0]), mm(v[1]), mm(v[2])) for v in verts],
                   [], [list(range(len(verts)))])
    me.update()
    o = bpy.data.objects.new(name, me)
    if mat:
        me.materials.append(mat)
    if thickness:
        s = o.modifiers.new("Solidify", "SOLIDIFY")
        s.thickness = mm(thickness)
        s.offset = 0.0
    link(o, col)
    return o


# =================================================================== scene

class Build:
    """One scene. The nine panels and the electronics pack are the same in
    every design; everything else the design itself decides."""

    def __init__(self, face_png, lit, cloth_name, tilt=0.0, lift=0.0):
        self.sc = W.clean()
        self.lit = lit
        self.face_png = face_png
        self.root = bpy.data.objects.new("Object", None)
        self.sc.collection.objects.link(self.root)
        self.wall_y = 0.0                      # set by place()
        self.root.rotation_euler = (math.pi / 2 + math.radians(tilt), 0, 0)
        self.lift = lift
        self.cols = {n: collection(n) for n in
                     ("Panels", "Face", "Body", "Halo", "Electronics", "Wiring", "Studio")}
        self.parts = {}
        c = CLOTH[cloth_name]
        self.m = dict(
            cloth=cloth_material(cloth_name, c),
            black=board_material("Body black", (0.017, 0.017, 0.018)),
            bone=board_material("Bone", (0.62, 0.60, 0.56), 0.90),
            stone=board_material("Cast stone", (0.085, 0.081, 0.074), 0.94),
            grey=board_material("Pale grey", (0.38, 0.375, 0.365), 0.88),
            card=board_material("Card", (0.19, 0.18, 0.165), 0.92),
            alu=W.brushed_material("Alloy", (0.80, 0.805, 0.82), 0.33, 0.20),
            anod=W.brushed_material("Anodised", (0.045, 0.045, 0.048), 0.36, 0.4),
            tin=W.brushed_material("Tinned copper", (0.75, 0.76, 0.74), 0.35),
            ply=W.plywood_material(),
            pcb=material("PCB dark", (0.012, 0.03, 0.02), 0.5),
            plastic=material("Panel plastic", (0.02, 0.02, 0.02), 0.55),
            white=material("White plastic", (0.85, 0.85, 0.82), 0.5),
            red=material("Red lead", (0.55, 0.03, 0.02), 0.5),
            blk=material("Black lead", (0.012, 0.012, 0.012), 0.5),
            smoke=material("Smoked acrylic", (0.30, 0.30, 0.32), 0.02,
                           transmission=1.0, ior=1.49),
            opal=material("Opal acrylic", (0.72, 0.72, 0.70), 0.28,
                          transmission=0.62, ior=1.0),
            brass=W.brushed_material("Brass", (0.86, 0.66, 0.30), 0.26, 0.3),
            leather=leather_material(),
            lacquer=material("Black lacquer", (0.010, 0.010, 0.011), 0.20, coat=0.7),
            walnut=walnut(),
        )
        self.led = W.led_material(face_png)
        if not lit:
            self.led.node_tree.nodes["Principled BSDF"].inputs[
                "Emission Strength"].default_value = 0.0

    # -- placement ---------------------------------------------------------
    def place(self, back_z, height=1500.0):
        """Put the object's rearmost face on the wall. `back_z` is that face
        in local mm; everything forward of it is the object."""
        self.wall_y = mm(-back_z)
        self.root.location = (0, self.wall_y, mm(height) + mm(self.lift))
        self.height = height
        return self

    def part(self, o, layer=0, parent=None):
        o.parent = parent or self.root
        self.parts[o.name] = (o, layer)
        return o

    # -- the nine panels ---------------------------------------------------
    def panels(self, cx=0.0, cy=0.0):
        half = FACE / 2
        for r in range(3):
            for c in range(3):
                px = cx - half + W.PANEL / 2 + c * W.PANEL
                py = cy + half - W.PANEL / 2 - r * W.PANEL
                n = r * 3 + c + 1
                self.part(box(f"Panel {n} PCB", (W.PANEL - 0.4, W.PANEL - 0.4, 1.6),
                              (px, py, -0.8), self.cols["Panels"], self.m["pcb"]), 3)
                bpy.ops.mesh.primitive_plane_add(size=1.0)
                f = bpy.context.active_object
                f.name = f"Panel {n} LEDs"
                f.scale = (mm(W.PANEL), mm(W.PANEL), 1)
                bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
                f.location = (mm(px), mm(py), mm(0.15))
                W.uv_square(f, c / 3, (2 - r) / 3, (c + 1) / 3, (3 - r) / 3)
                f.data.materials.append(self.led)
                link(f, self.cols["Panels"])
                self.part(f, 3)
                zb = -W.PANEL_T + 5.5
                for k, dx in enumerate((48, -48)):
                    self.part(box(f"Panel {n} HUB75 {k}", W.IDC, (px + dx, py + 44, zb),
                                  self.cols["Panels"], self.m["plastic"]), 3)
                self.part(box(f"Panel {n} VH4", (12.0, 9.0, 8.0), (px, py - 58, zb),
                              self.cols["Panels"], self.m["white"]), 3)
                for k, (ax, ay) in enumerate((W.PANEL_M3[0], W.PANEL_M3[1],
                                              W.PANEL_M3[6], W.PANEL_M3[7])):
                    self.part(cylinder(f"Panel {n} magnet {k}", W.MAG_D / 2, W.MAG_FOOT_H,
                                       (px + ax, py + ay, -W.PANEL_T - W.MAG_FOOT_H / 2),
                                       self.cols["Panels"], self.m["tin"], verts=24), 3)
        W.borrow("P Panels", self.root, self.parts, 3,
                 keep=lambda n: "PCB face" not in n and "emitters" not in n)
        at = bpy.data.objects.get("Atelier P Panels")
        if at and (cx or cy):
            at.location.x += mm(cx)
            at.location.z += mm(-cy)
        return self

    # -- the box of parts that has to live somewhere -----------------------
    def electronics(self, psu, bars, fuse, pi, seat, wide=False):
        W.borrow("E Power", self.root, self.parts, 6, centre=(*psu, 0), seat=seat,
                 keep=lambda n: not any(k in n.lower() for k in
                                        ("inlet", "iec", "c14", "mounting tab", "sl22", "ntc")))
        W.borrow("D Controller", self.root, self.parts, 6, centre=(*pi, 0), seat=seat - 3)
        W.borrow("E Bus bars", self.root, self.parts, 6, centre=(*bars, 0), seat=seat)
        W.borrow("U Unresolved fit", self.root, self.parts, 6, centre=(*fuse, 0), seat=seat,
                 keep=lambda n: any(k in n.lower() for k in
                                    ("fuse", "nilight", "heat", "shrink", "10a", "butt")))
        self.pack = dict(psu=psu, bars=bars, fuse=fuse, pi=pi, seat=seat)
        return self

    def mains(self, at, rot=(0, 0, 0), label="C14 inlet, switch and fuse"):
        """The one part the owner touches. Every design puts it somewhere a
        hand goes without looking."""
        o = self.part(box("Mains module", INLET, at, self.cols["Electronics"],
                          self.m["anod"], bevel=1.2), 6)
        o.rotation_euler = rot
        r = self.part(box("Rocker", (18.0, 12.0, 2.0),
                          (at[0] - 12, at[1], at[2] + INLET[2] / 2 + 0.6),
                          self.cols["Electronics"], self.m["grey"], bevel=0.6), 6)
        r.rotation_euler = rot
        s = self.part(box("Socket mouth", (24.0, 20.0, 2.0),
                          (at[0] + 11, at[1], at[2] + INLET[2] / 2 + 0.4),
                          self.cols["Electronics"], self.m["black"]), 6)
        s.rotation_euler = rot
        self.inlet_at = at
        return self

    def cut(self, target, name, size, at):
        """Subtract a box from a mesh object."""
        CUT = bpy.data.collections.get("Cutters body") or collection("Cutters body")
        CUT.hide_render = True
        c = self.part(box(name, size, at, CUT), 5)
        m = target.modifiers.new(name, "BOOLEAN")
        m.operation, m.object, m.solver = "DIFFERENCE", c, "EXACT"
        return c

    def cut_outline(self, target, name, outline, t, z):
        """Subtract a prism of any outline. A square cutter gives a square
        opening, which is what put a hard corner in the middle of a shell
        whose own corner is a 50 mm arc."""
        CUT = bpy.data.collections.get("Cutters body") or collection("Cutters body")
        CUT.hide_render = True
        c = self.part(slab(name, outline, t, z, CUT, None), 5)
        m = target.modifiers.new(name, "BOOLEAN")
        m.operation, m.object, m.solver = "DIFFERENCE", c, "EXACT"
        return c

    def well(self, opening, z_from, z_to, mat, t=6.0, cy=0.0):
        """Four walls lining a recess, from the steel to the glass."""
        h = z_to - z_from
        zc = (z_from + z_to) / 2
        ho = opening / 2 + t / 2
        for i, (dx, dy, sx, sy) in enumerate((
                (0, ho, opening + 2 * t, t), (0, -ho, opening + 2 * t, t),
                (-ho, 0, t, opening), (ho, 0, t, opening))):
            self.part(box(f"Well {i}", (sx, sy, h), (dx, cy + dy, zc), self.cols["Face"], mat), 2)

    # -- the halo ----------------------------------------------------------
    def halo(self, w, h, z, inset=12.0, strength=34.0, cx=0.0, cy=0.0):
        cs = halo_colours(self.face_png)
        hw, hh = w / 2, h / 2
        for e, (px, py, ax) in enumerate((
                (cx, cy - hh + inset, "x"), (cx + hw - inset, cy, "y"),
                (cx, cy + hh - inset, "x"), (cx - hw + inset, cy, "y"))):
            span = (w if ax == "x" else h) - 2 * inset
            zl = span / HALO_SEGS
            for s in range(HALO_SEGS):
                off = -span / 2 + zl / 2 + s * zl
                col = cs[(e * HALO_SEGS + s) % len(cs)]
                for u in range(HALO_SUB):
                    sub = -zl / 2 + zl / (2 * HALO_SUB) + u * zl / HALO_SUB
                    if ax == "x":
                        at, size = (px + off + sub, py, z), (zl / HALO_SUB - 3, 9.0, 4.0)
                    else:
                        at, size = (px, py + off + sub, z), (9.0, zl / HALO_SUB - 3, 4.0)
                    nm = f"Halo {e}{s}{u}"
                    em = material(nm, (0.02, 0.02, 0.02), 0.5,
                                  emit=col if self.lit else (0, 0, 0),
                                  emit_strength=strength if self.lit else 0.0)
                    self.part(box(nm, size, at, self.cols["Halo"], em), 6)
        return self

    # -- room --------------------------------------------------------------
    def studio(self, floor_y=0.0):
        S = self.cols["Studio"]
        plaster = material("Plaster", (0.50, 0.47, 0.44), 0.92)
        floor_m = material("Floor", (0.055, 0.052, 0.048), 0.34)
        bpy.ops.mesh.primitive_plane_add(size=1.0)
        wp = bpy.context.active_object
        wp.name = "Room wall"
        wp.scale = (7.0, 4.5, 1)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        wp.rotation_euler = (math.pi / 2, 0, 0)
        wp.location = (0, 2 * self.wall_y + 0.002, 1.7)
        wp.data.materials.append(plaster)
        link(wp, S)
        bpy.ops.mesh.primitive_plane_add(size=1.0)
        fl = bpy.context.active_object
        fl.name = "Floor"
        fl.scale = (9.0, 9.0, 1)
        bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
        fl.location = (0, -2.5, floor_y)
        fl.data.materials.append(floor_m)
        link(fl, S)
        world = bpy.data.worlds.new("World")
        self.sc.world = world
        if hasattr(world, "use_nodes"):
            world.use_nodes = True
        world.node_tree.nodes["Background"].inputs[0].default_value = (0.012, 0.012, 0.013, 1)

        def area(name, loc, target, power, size, color=(1, 1, 1), size_y=None):
            ld = bpy.data.lights.new(name, "AREA")
            ld.energy, ld.size, ld.color = power, size, color
            if size_y:
                ld.shape, ld.size_y = "RECTANGLE", size_y
            lo = bpy.data.objects.new(name, ld)
            lo.location = loc
            lo.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
            self.sc.collection.objects.link(lo)
            return lo

        z = mm(self.height)
        self.lights = {
            "key": area("Key", (-2.4, -1.2, z + 1.8), (-0.25, 0.15, z - 0.15), 260, 0.8,
                        (1.0, 0.96, 0.90)),
            "fill": area("Fill", (2.5, -1.3, z + 1.4), (0.35, 0.10, z - 0.20), 110, 1.5,
                         (0.90, 0.94, 1.0)),
            "rim": area("Rim", (1.8, 0.7, z + 1.4), (0.20, 0.0, z + 0.05), 190, 0.22,
                        (1.0, 0.98, 0.95), size_y=2.0),
            "back": area("Back light", (0.8, 1.9, z + 0.9), (0, 0.1, z - 0.05), 150, 1.6),
        }
        self.lights["back"].hide_render = True
        cd = bpy.data.cameras.new("Camera")
        cd.lens, cd.sensor_width = 50, 36
        self.cam = bpy.data.objects.new("Camera", cd)
        self.sc.collection.objects.link(self.cam)
        self.sc.camera = self.cam
        return self

    # -- the carcass every design hides its parts in ------------------------
    def carcass(self, w, h, cx=0.0, cy=0.0, depth=CAVITY, back=True,
                steel=520.0, mat=None, halo=True, halo_strength=34.0):
        """Board, steel skin, perimeter rails, back panel, halo. The fifteen
        openings behind the panels are unchanged from the buildable design and
        are left out here only because a panel covers every one of them."""
        mat = mat or self.m["black"]
        fur = W.FURRING
        self.part(box("Board", (w, h, W.PLY_T), (cx, cy, Z_STEEL_BACK - W.PLY_T / 2),
                      self.cols["Body"], mat, bevel=0.6), 5)
        self.part(box("Steel skin", (steel, steel, W.STEEL_T),
                      (cx, cy, (Z_STEEL_FRONT + Z_STEEL_BACK) / 2), self.cols["Body"], mat), 5)
        z_frame_back = Z_PLY_BACK - depth
        z_mid = Z_PLY_BACK - depth / 2
        if depth > 2:
            for i, (sx, sy, bw, bh) in enumerate((
                    (cx, cy + h / 2 - fur / 2, w, fur), (cx, cy - h / 2 + fur / 2, w, fur),
                    (cx - w / 2 + fur / 2, cy, fur, h - 2 * fur),
                    (cx + w / 2 - fur / 2, cy, fur, h - 2 * fur))):
                self.part(box(f"Rail {i}", (bw, bh, depth), (sx, sy, z_mid),
                              self.cols["Body"], mat), 5)
        z_back_face = z_frame_back
        if back:
            self.part(box("Back panel", (w, h, BACK_T), (cx, cy, z_frame_back - BACK_T / 2),
                          self.cols["Body"], mat, bevel=0.5), 5)
            z_back_face = z_frame_back - BACK_T
        if halo:
            self.halo(w, h, z_back_face - 3.0, strength=halo_strength, cx=cx, cy=cy)
        return z_back_face

    def glass(self, size, cx=0.0, cy=0.0, mat=None):
        self.part(box("Smoked acrylic", (size, size, ACR_T), (cx, cy, AIR + ACR_T / 2),
                      self.cols["Face"], mat or self.m["smoke"], bevel=0.4), 1)
        return AIR + ACR_T

    def aperture_plate(self, w, h, t, z_back, opening, cx=0.0, cy=0.0, ay=0.0,
                       mat=None, surround_from=None, sw=20.0, bezel_mat=None,
                       surround_mat=None):
        """A sheet with a square hole and a fine bright edge standing in it,
        plus the perimeter wall that carries it. Without that wall the plate
        floats 35 mm off the carcass over a visible void, which is exactly
        what the first side render showed."""
        CUT = bpy.data.collections.get("Cutters face") or collection("Cutters face")
        CUT.hide_render = True
        zc = z_back + t / 2
        face_mat = mat or self.m["cloth"]
        if surround_from is not None and z_back - surround_from > 1.0:
            sh, sz = z_back - surround_from, (surround_from + z_back) / 2
            for i, (dx, dy, sx, sy) in enumerate((
                    (0, h / 2 - sw / 2, w, sw), (0, -h / 2 + sw / 2, w, sw),
                    (-w / 2 + sw / 2, 0, sw, h - 2 * sw),
                    (w / 2 - sw / 2, 0, sw, h - 2 * sw))):
                self.part(box(f"Surround {i}", (sx, sy, sh), (cx + dx, cy + dy, sz),
                              self.cols["Face"], surround_mat or face_mat, bevel=0.6), 2)
        p = self.part(box("Front plate", (w, h, t), (cx, cy, zc), self.cols["Face"],
                          face_mat, bevel=0.5), 1)
        c = self.part(box("Aperture", (opening, opening, t + 8), (cx, cy + ay, zc), CUT), 1)
        m = p.modifiers.new("Opening", "BOOLEAN")
        m.operation, m.object, m.solver = "DIFFERENCE", c, "EXACT"
        ho = opening / 2 + 1.5
        for i, (dx, dy, sx, sy) in enumerate((
                (0, ho, opening + 6, 3.0), (0, -ho, opening + 6, 3.0),
                (-ho, 0, 3.0, opening), (ho, 0, 3.0, opening))):
            self.part(box(f"Bezel {i}", (sx, sy, t + 0.6),
                          (cx + dx, cy + ay + dy, zc), self.cols["Face"],
                          bezel_mat or self.m["alu"], bevel=0.3), 1)
        return zc + t / 2


# ================================================================== designs

def sleeve(b):
    """An oversized record jacket. The front card overhangs a smaller body and
    stops 34 mm short of the top, so the object is open along that edge the way
    a sleeve is. The mains module sits in the opening: switching it on is
    reaching in, which is the only gesture the object asks for."""
    W_, H_ = 544.0, 566.0
    SLOT = 34.0
    b.panels()
    z_back = b.carcass(W_ - 24, H_, depth=CAVITY, steel=500.0)
    b.glass(510.0)
    plate_h = H_ - SLOT
    front = b.aperture_plate(W_, plate_h, 11.0, AIR + ACR_T, FACE + 16,
                             cy=-SLOT / 2, ay=SLOT / 2,
                             surround_from=Z_STEEL_FRONT, sw=16.0)
    # the opening. A record stands a little proud of its sleeve, so the card
    # inside it does too, and the mains module sits behind that edge.
    b.part(box("Inner card", (W_ - 34, 3.0, 26.0), (0, H_ / 2 - 15.0, -1.0),
               b.cols["Face"], b.m["card"], bevel=0.6), 5)
    b.mains((160.0, H_ / 2 - 15.0, -12.0))
    b.electronics(psu=(-20.0, -165.0), bars=(-165.0, 130.0), fuse=(-35.0, 25.0),
                  pi=(175.0, 130.0), seat=Z_PLY_BACK)
    return dict(w=W_, h=H_, front=front, back=z_back, height=1500.0, label="Sleeve")


def lean(b):
    """It does not hang. A slab tipped back eight degrees, standing in a solid
    foot on a sideboard. No cleat, no wall fixing, no holes in anyone's
    plaster, and it moves rooms in ten seconds. The switch is in the foot's
    right end, where a hand already goes to steady it."""
    W_, H_ = 600.0, 640.0
    b.panels()
    # wrapped all round, not a cloth face on a black box: this one is
    # furniture, and furniture is one material
    z_back = b.carcass(W_, H_, depth=CAVITY, steel=520.0, halo_strength=26.0,
                       mat=b.m["cloth"])
    b.glass(520.0)
    front = b.aperture_plate(W_, H_, 14.0, AIR + ACR_T, FACE + 24, mat=b.m["cloth"],
                             surround_from=Z_STEEL_FRONT, sw=22.0)
    b.electronics(psu=(-20.0, -215.0), bars=(-180.0, 170.0), fuse=(-40.0, 60.0),
                  pi=(190.0, 170.0), seat=Z_PLY_BACK)
    return dict(w=W_, h=H_, front=front, back=z_back, height=1275.0,
                label="Lean", foot=True)


def system(b):
    """Two pieces, after Rams' 606: a small number of components hung on a
    wall and rearrangeable. Because the machine moved out of the picture, the
    picture becomes a 54 mm plate instead of a 121 mm box. The module below is
    an amplifier: vented, alloy-faced, with a real front-panel switch."""
    PW, PH = 600.0, 600.0
    MW, MH, MD = 640.0, 180.0, 95.0
    GAP = 120.0
    my = -PH / 2 - GAP - MH / 2
    b.panels()
    z_back = b.carcass(PW, PH, depth=12.0, steel=520.0, halo_strength=30.0)
    b.glass(520.0)
    front = b.aperture_plate(PW, PH, 10.0, AIR + ACR_T, FACE + 18, mat=b.m["anod"],
                             surround_from=Z_STEEL_FRONT, sw=18.0)
    # the module: its own little box, forward of the plate because it is thicker
    mz = Z_PLY_BACK - 12.0 - BACK_T                    # the plate's back face
    m_front = mz + MD
    b.part(box("Module body", (MW, MH, MD), (0, my, mz + MD / 2), b.cols["Body"],
               b.m["black"], bevel=1.2), 5)
    b.part(box("Module face", (MW, MH, 3.0), (0, my, m_front + 1.5), b.cols["Face"],
               b.m["alu"], bevel=0.8), 5)
    for i in range(7):                                  # vents, left of centre
        b.part(box(f"Vent {i}", (9.0, MH - 54, 1.6), (-250 + i * 16, my, m_front + 3.2),
                   b.cols["Face"], b.m["anod"]), 5)
    b.mains((250.0, my + 20.0, m_front - INLET[2] / 2 + 3.0))
    b.electronics(psu=(-180.0, my - 25.0), bars=(30.0, my + 52.0),
                  fuse=(30.0, my - 35.0), pi=(175.0, my - 40.0), seat=m_front - 6.0)
    # the umbilical, shown rather than hidden
    b.part(cable("Umbilical", [(-PW / 2 + 60, -PH / 2 + 6, mz - 6),
                               (-PW / 2 + 58, -PH / 2 - 46, mz + 26),
                               (-PW / 2 + 70, my + MH / 2 + 34, mz + 40),
                               (-PW / 2 + 78, my + MH / 2 - 6, mz + 52)],
                4.2, b.cols["Wiring"], b.m["blk"]), 6)
    return dict(w=MW, h=PH + GAP + MH, front=front, back=z_back, height=1500.0,
                label="System", centre_y=(PH / 2 + (my - MH / 2)) / 2)


def splay(b):
    """A funnel. Wide where you stand, narrowing 78 mm back to the picture, so
    the artwork floods four pale sloping walls with its own colour and the
    object blooms in whatever is playing. Off, a faceted block. Nothing else
    here does anything like it, and it is four trapezoids of plywood."""
    OUT, IN_, DEEP = 660.0, 500.0, 78.0
    b.panels()
    z_back = b.carcass(OUT, OUT, depth=CAVITY, steel=520.0, halo_strength=28.0)
    z_glass = b.glass(520.0)
    o, i = OUT / 2, IN_ / 2
    zo, zi = z_glass + DEEP, z_glass
    for n, (a, c, d, e) in enumerate((
            ((-o, o, zo), (o, o, zo), (i, i, zi), (-i, i, zi)),        # top
            ((o, -o, zo), (-o, -o, zo), (-i, -i, zi), (i, -i, zi)),    # bottom
            ((-o, -o, zo), (-o, o, zo), (-i, i, zi), (-i, -i, zi)),    # left
            ((o, o, zo), (o, -o, zo), (i, -i, zi), (i, i, zi)))):      # right
        b.part(poly(f"Splay {n}", (a, c, d, e), b.cols["Face"], b.m["bone"], 6.0), 1)
    for n, (dx, dy, sx, sy) in enumerate((
            (0, o - 3, OUT, 6.0), (0, -o + 3, OUT, 6.0),
            (-o + 3, 0, 6.0, OUT - 12), (o - 3, 0, 6.0, OUT - 12))):
        b.part(box(f"Rim {n}", (sx, sy, 5.0), (dx, dy, zo - 2.5), b.cols["Face"],
                   b.m["alu"], bevel=0.4), 1)
    b.mains((210.0, -o + 2.0, zo - 46.0), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -225.0), bars=(-190.0, 175.0), fuse=(-45.0, 60.0),
                  pi=(200.0, 175.0), seat=Z_PLY_BACK)
    return dict(w=OUT, h=OUT, front=zo, back=z_back, height=1500.0, label="Splay",
                lights=(0.38, 0.30, 0.55))


def case(b):
    """Index's honest aluminium cassette with Console's charcoal wool face,
    the black anodised reveal from the walnut design standing 3 mm proud of
    the glass, the picture set 15 mm back into a black well, and the boxed
    build's vented enclosure. Mains on the underside, right, where Index put
    it. The cool one."""
    S, RECESS_ = 540.0, 15.0
    b.panels()
    z_back = b.carcass(S, S, depth=CAVITY, steel=500.0, mat=b.m["alu"], halo_strength=30.0)
    z_acr_back = AIR + RECESS_
    b.part(box("Smoked acrylic", (520.0, 520.0, ACR_T), (0, 0, z_acr_back + ACR_T / 2),
               b.cols["Face"], b.m["smoke"], bevel=0.4), 1)
    b.well(500.0, Z_STEEL_FRONT, z_acr_back, b.m["anod"])
    front = b.aperture_plate(S, S, 10.0, z_acr_back + ACR_T, 500.0, mat=b.m["cloth"],
                             surround_from=Z_STEEL_FRONT, sw=18.0,
                             bezel_mat=b.m["anod"], surround_mat=b.m["alu"])
    b.mains((165.0, -S / 2 + 2.0, Z_PLY_BACK - CAVITY / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -180.0), bars=(-175.0, 150.0), fuse=(-35.0, 40.0),
                  pi=(180.0, 150.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=front, back=z_back, height=1500.0, label="Case", switch_down=True)


def hearth(b):
    """Soft's broken rectangle tamed to a chamfered square, in the walnut
    design's veneer with its brass keys moved to the chamfers; the picture
    40 mm down a well lined in Vitrine's oatmeal cloth, behind a brass bezel;
    Soft's black power shoe at the bottom. The warm one."""
    S, C, RECESS_, WALL = 640.0, 70.0, 40.0, 6.0
    z_acr_back = AIR + RECESS_
    z_front = z_acr_back + ACR_T
    z_frame_back = Z_PLY_BACK - CAVITY
    z_back = z_frame_back - BACK_T
    b.panels()
    b.carcass(560.0, 560.0, depth=0.0, back=False, halo=False, steel=496.0, mat=b.m["black"])
    depth = z_front - z_frame_back
    shell = b.part(slab("Shell", chamfered_rect(S, S, C), depth, (z_front + z_frame_back) / 2,
                        b.cols["Body"], b.m["walnut"]), 5)
    b.cut(shell, "Shell cavity", (560.0, 560.0, (Z_STEEL_FRONT + 1) - z_frame_back + 4),
          (0, 0, ((Z_STEEL_FRONT + 1) + z_frame_back) / 2 - 2))
    b.cut(shell, "Shell aperture", (500.0 + 2 * WALL, 500.0 + 2 * WALL, z_front - Z_STEEL_FRONT + 8),
          (0, 0, (z_front + Z_STEEL_FRONT) / 2 + 2))
    b.part(slab("Back panel", chamfered_rect(S, S, C), BACK_T, z_frame_back - BACK_T / 2,
                b.cols["Body"], b.m["black"]), 5)
    b.halo(S - 2 * C, S - 2 * C, z_back - 3.0, strength=26.0)
    b.well(500.0, Z_STEEL_FRONT, z_acr_back, b.m["cloth"], t=WALL)
    b.part(box("Smoked acrylic", (500.0 + 2 * WALL - 1, 500.0 + 2 * WALL - 1, ACR_T),
               (0, 0, z_acr_back + ACR_T / 2), b.cols["Face"], b.m["smoke"], bevel=0.4), 1)
    ho = 250.0 + 1.5
    for i, (dx, dy, sx, sy) in enumerate((
            (0, ho, 506.0, 3.0), (0, -ho, 506.0, 3.0), (-ho, 0, 3.0, 500.0), (ho, 0, 3.0, 500.0))):
        b.part(box(f"Brass bezel {i}", (sx, sy, 3.0), (dx, dy, z_front - 1.0), b.cols["Face"],
                   b.m["brass"], bevel=0.3), 1)
    # brass keys let into the four chamfers, the walnut design's splines
    for i, (sx, sy) in enumerate(((1, 1), (-1, 1), (-1, -1), (1, -1))):
        k = b.part(box(f"Brass key {i}", (12.0, 1.6, depth - 20.0),
                       (sx * (S / 2 - C / 2 + 1.0), sy * (S / 2 - C / 2 + 1.0), (z_front + z_frame_back) / 2),
                       b.cols["Face"], b.m["brass"]), 5)
        k.rotation_euler = (0, 0, math.radians(45.0 * sx * sy))
    # the power shoe: one precise black interruption in a soft form
    shoe = (-140.0, -S / 2 - 12.0, Z_PLY_BACK - CAVITY / 2)
    b.part(box("Power shoe", (76.0, 26.0, 46.0), shoe, b.cols["Electronics"], b.m["black"], bevel=1.2), 6)
    b.mains((shoe[0], shoe[1] - 12.0, shoe[2]), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -190.0), bars=(-180.0, 160.0), fuse=(-40.0, 45.0),
                  pi=(190.0, 160.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=z_front, back=z_back, height=1500.0, label="Hearth", switch_down=True)


def strap(b):
    """The original, second pass. The brass hook and the leather strap are
    gone: it hangs flush like the rest of the family, and what is left is the
    shell itself. Every border is now a parallel curve of the outside, so the
    50 mm corner runs all the way in: 34 mm at the brass ring's outer edge,
    32 mm at the aperture, 30 mm at the ring's inner edge, all four arcs
    struck from one centre. The picture is flush behind smoked acrylic inside
    that ring. Mains on the bottom edge in a brass escutcheon."""
    S, R = 540.0, 50.0
    OPEN = 504.0                       # the aperture in the shell's front lip
    BR_O, BR_I = 508.0, 500.0          # the brass ring, 4 mm of face
    def concentric(w):
        """The same corner, offset inward: r shrinks by whatever the border
        is wide, which is what makes two curves read as one."""
        return R - (S - w) / 2
    z_front = AIR + ACR_T + 2.0
    z_frame_back = Z_PLY_BACK - CAVITY
    z_back = z_frame_back - BACK_T
    b.panels()
    b.carcass(500.0, 500.0, depth=0.0, back=False, halo=False, steel=496.0, mat=b.m["black"])
    depth = z_front - z_frame_back
    shell = b.part(slab("Shell", rounded_rect(S, S, R), depth, (z_front + z_frame_back) / 2,
                        b.cols["Body"], b.m["lacquer"]), 5)
    b.cut(shell, "Shell cavity", (502.0, 502.0, (Z_STEEL_FRONT + 1) - z_frame_back + 4),
          (0, 0, ((Z_STEEL_FRONT + 1) + z_frame_back) / 2 - 2))
    b.cut_outline(shell, "Shell aperture", rounded_rect(OPEN, OPEN, concentric(OPEN)),
                  z_front - Z_STEEL_FRONT + 8, (z_front + Z_STEEL_FRONT) / 2 + 2)
    b.part(slab("Back panel", rounded_rect(S, S, R), BACK_T, z_frame_back - BACK_T / 2,
                b.cols["Body"], b.m["black"]), 5)
    b.halo(S - 40, S - 40, z_back - 3.0, strength=30.0)
    b.part(box("Smoked acrylic", (503.0, 503.0, ACR_T), (0, 0, AIR + ACR_T / 2),
               b.cols["Face"], b.m["smoke"], bevel=0.4), 1)
    reveal = b.part(slab("Brass reveal", rounded_rect(BR_O, BR_O, concentric(BR_O)),
                         2.4, z_front - 0.8, b.cols["Face"], b.m["brass"]), 1)
    b.cut_outline(reveal, "Brass reveal opening",
                  rounded_rect(BR_I, BR_I, concentric(BR_I)), 8.0, z_front - 0.8)
    PADS = 25.0
    for i, (sx, sy) in enumerate(((-1, 1), (1, 1), (-1, -1), (1, -1))):
        b.part(box(f"Wall pad {i}", (30, 30, PADS), (sx * (S / 2 - 60), sy * (S / 2 - 60), z_back - PADS / 2),
                   b.cols["Body"], b.m["black"]), 7)
    # mains in a brass escutcheon on the bottom edge, right
    b.part(box("Escutcheon", (66.0, 2.0, 44.0), (165.0, -S / 2 - 1.0, Z_PLY_BACK - CAVITY / 2),
               b.cols["Electronics"], b.m["brass"], bevel=0.4), 6)
    b.mains((165.0, -S / 2 + 2.0, Z_PLY_BACK - CAVITY / 2), rot=(math.pi / 2, 0, 0))
    b.electronics(psu=(-20.0, -165.0), bars=(-165.0, 130.0), fuse=(-35.0, 25.0),
                  pi=(175.0, 130.0), seat=Z_PLY_BACK)
    return dict(w=S, h=S, front=z_front, back=z_back, height=1500.0,
                label="Strap", centre_y=0.0, pads=PADS, switch_down=True)


DESIGNS = {"sleeve": sleeve, "lean": lean, "system": system, "splay": splay,
           "case": case, "hearth": hearth, "strap": strap}
DEFAULT_CLOTH = {"sleeve": "oxblood", "lean": "oatmeal", "system": "charcoal",
                 "splay": "ink", "case": "charcoal", "hearth": "oatmeal", "strap": "charcoal"}


# ==================================================================== main

def build_foot(b, info):
    """Lean's foot, in world space: the slab tilts, the foot does not."""
    S = b.cols["Body"]
    top = SHELF + 0.055
    # eight degrees pushes the slab's foot forward by H/2 * sin(8), and the
    # foot has to be under that, not under where an upright slab would be
    y = b.root.location.y + mm(info["h"] / 2) * math.sin(math.radians(8.0))
    for name, size, at, mat in (
            ("Foot", (660.0, 150.0, 55.0), (0, 0, 0), b.m["stone"]),
            ("Foot rebate", (620.0, 26.0, 14.0), (0, -14.0, 27.0), b.m["black"])):
        o = box(name, size, at, S, mat, bevel=1.5)
        o.location = (0, y + mm(at[1]), SHELF + mm(size[2]) / 2 + mm(at[2]))
        b.parts[o.name] = (o, 7)
    m = box("Foot mains", INLET, (0, 0, 0), b.cols["Electronics"], b.m["anod"], bevel=1.2)
    m.rotation_euler = (0, math.pi / 2, 0)
    m.location = (mm(330.0) - mm(INLET[2]) / 2, y, top - mm(28.0))
    b.parts[m.name] = (m, 7)
    b.inlet_world = (mm(330.0), y, top - mm(28.0))
    b.inlet_at = (330.0, -320.0, 0.0)          # in the foot, not the slab
    return top


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="design/renders")
    ap.add_argument("--face", default="")
    ap.add_argument("--samples", type=int, default=180)
    ap.add_argument("--design", default="sleeve", choices=sorted(DESIGNS))
    ap.add_argument("--cloth", default="")
    ap.add_argument("--views", default="hero,front,side,detail,back,off")
    ap.add_argument("--prefix", default="")
    args = ap.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    prefix = args.prefix or args.design
    face = os.path.abspath(args.face) if args.face else ""
    views = args.views.split(",")
    cloth = args.cloth or DEFAULT_CLOTH[args.design]
    tilt = 8.0 if args.design == "lean" else 0.0

    def scene(lit=True):
        b = Build(face, lit, cloth, tilt=tilt)
        info = DESIGNS[args.design](b)
        b.place(info["back"] - info.get("pads", 0.0), info["height"])
        if args.design == "lean":
            b.root.location = (0, b.wall_y + 0.030, mm(info["height"]))
        b.studio(floor_y=SHELF if args.design == "lean" else 0.0)
        ks, fs, rs = info.get("lights", (1.0, 1.0, 1.0))
        b.lights["key"].data.energy *= ks
        b.lights["fill"].data.energy *= fs
        b.lights["rim"].data.energy *= rs
        if info.get("foot"):
            build_foot(b, info)
        else:
            b.inlet_world = (mm(b.inlet_at[0]),
                             b.wall_y - mm(b.inlet_at[2]),
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
        # a switch that faces the floor has to be photographed from the floor
        t = b.inlet_world
        if info.get("switch_down"):
            W.aim(b.cam, (t[0] + 0.16, t[1] - 0.40, t[2] - 0.26), t, lens=55, fstop=6.3, focus=t)
        else:
            W.aim(b.cam, (t[0] + 0.10, t[1] - 0.36, t[2] + 0.20), t, lens=60, fstop=5.6, focus=t)
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
        b.lights["key"].data.energy = 460
        b.lights["fill"].data.energy = 200
        C = (0.0, b.wall_y - mm(info["front"]) * 0.5,
             mm(info["height"]) + mm(info.get("centre_y", 0.0)))
        W.aim(b.cam, (-span * 1.15, -span * 2.4, C[2] + span * 0.22), C, lens=55, fstop=4.5)
        W.render(b.sc, os.path.join(args.out, f"{prefix}-off.png"), args.samples)

    print("design %s, cloth %s" % (args.design, cloth))
    print("envelope %.0f x %.0f mm, %.1f mm front to back"
          % (info["w"], info["h"], info["front"] - info["back"]))
    print("mains module at local x %.0f y %.0f z %.0f"
          % (b.inlet_at[0], b.inlet_at[1], b.inlet_at[2]))


SHELF = 0.90                   # DESIGN  a sideboard top, for the one that stands

if __name__ == "__main__":
    main()
