#!/usr/bin/env python3
"""A 1:1 model of the Gemini TT-900 stereo turntable system, both finishes.

Built to the maker's numbers: turntable 406 x 324 x 90 mm, each speaker
127 x 156 x 203 mm, and to the product photographs for everything the sheet
leaves out: a thick slab plinth on an inset base so it floats on four feet,
no dust cover, a 300 mm platter under a felt mat with the wordmark, a
straight tonearm on a round base at the rear right with a rectangular
headshell, three knobs along the front right (speed, pitch, volume), the
rear panel (auto-stop switch, RCA pair, spring speaker terminals, mode
switch, DC jack, rocker power switch), and two two-way speakers with a
diamond tweeter plate above the woofer.

    Blender -b -P design/tt900/tt900.py -- black|white [--renders DIR]

Origin: centre of the plinth's footprint on the table, x across (406),
y depth (324, front is -y), z up. Everything below is in millimetres and
scaled to metres on the way in. Writes design/tt900/tt900-<finish>.blend, a
glTF of the set, and the renders: hero, front and top.
"""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

bpy.ops.wm.read_factory_settings(use_empty=True)   # no stock cube, light or camera

HERE = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
FINISH = argv[0] if argv else "black"
OUT = argv[argv.index("--renders") + 1] if "--renders" in argv else os.path.join(HERE, "renders")
os.makedirs(OUT, exist_ok=True)


def mm(v):
    return v / 1000.0


# ---------------------------------------------------------------- materials

def mat(name, base, rough=0.5, metal=0.0, coat=0.0, coat_rough=0.05, emission=None, strength=1.0, bump=0.0, bump_scale=200.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*base, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if coat:
        b.inputs["Coat Weight"].default_value = coat
        b.inputs["Coat Roughness"].default_value = coat_rough
    if emission:
        b.inputs["Emission Color"].default_value = (*emission, 1)
        b.inputs["Emission Strength"].default_value = strength
    if bump:
        tex = nt.nodes.new("ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = bump_scale
        tex.inputs["Detail"].default_value = 8
        bp = nt.nodes.new("ShaderNodeBump")
        bp.inputs["Strength"].default_value = bump
        nt.links.new(tex.outputs["Fac"], bp.inputs["Height"])
        nt.links.new(bp.outputs["Normal"], b.inputs["Normal"])
    return m


BLACK = FINISH == "black"
M = dict(
    body=mat("body", (0.008, 0.008, 0.009) if BLACK else (0.86, 0.86, 0.85), rough=0.12 if BLACK else 0.16, coat=0.7, coat_rough=0.05),
    base=mat("base", (0.01, 0.01, 0.011), rough=0.35),
    plastic=mat("plastic", (0.012, 0.012, 0.013), rough=0.42),
    felt=mat("felt", (0.009, 0.009, 0.01), rough=1.0, bump=0.35, bump_scale=900),
    rubber=mat("rubber", (0.015, 0.015, 0.015), rough=0.85),
    chrome=mat("chrome", (0.9, 0.9, 0.92), rough=0.14, metal=1.0),
    steel=mat("steel", (0.6, 0.6, 0.62), rough=0.3, metal=1.0),
    red=mat("red", (0.72, 0.04, 0.03), rough=0.35, coat=0.5),
    white=mat("white_print", (0.92, 0.92, 0.92), rough=0.6),
    cone=mat("cone", (0.02, 0.02, 0.022), rough=0.55, bump=0.25, bump_scale=60),
    cabinet=mat("cabinet", (0.012, 0.012, 0.013) if BLACK else (0.88, 0.88, 0.87), rough=0.35 if BLACK else 0.45, coat=0.3),
    baffle=mat("baffle", (0.012, 0.012, 0.013) if BLACK else (0.88, 0.88, 0.87), rough=0.45),
    floor=mat("floor", (0.88, 0.88, 0.88), rough=0.45, coat=0.25, coat_rough=0.25),
)

# ---------------------------------------------------------------- builders

COLL = bpy.data.collections.new("TT-900")
bpy.context.scene.collection.children.link(COLL)


def link(o):
    for c in o.users_collection:
        c.objects.unlink(o)
    COLL.objects.link(o)
    return o


def box(name, size, loc, m, bevel=0.0, rot=(0, 0, 0), segments=4):
    bpy.ops.mesh.primitive_cube_add(size=1)
    o = bpy.context.object
    o.name = name
    o.data.transform(Matrix.Diagonal((mm(size[0]), mm(size[1]), mm(size[2]), 1)))
    o.location = (mm(loc[0]), mm(loc[1]), mm(loc[2]))
    o.rotation_euler = rot
    o.data.materials.append(m)
    if bevel:
        b = o.modifiers.new("bevel", "BEVEL")
        b.width, b.segments = mm(bevel), segments
    bpy.ops.object.shade_smooth_by_angle()
    return link(o)


def cyl(name, r, depth, loc, m, rot=(0, 0, 0), verts=96, bevel=0.0, segments=4):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=mm(r), depth=mm(depth))
    o = bpy.context.object
    o.name = name
    o.location = (mm(loc[0]), mm(loc[1]), mm(loc[2]))
    o.rotation_euler = rot
    o.data.materials.append(m)
    if bevel:
        b = o.modifiers.new("bevel", "BEVEL")
        b.width, b.segments = mm(bevel), segments
    bpy.ops.object.shade_smooth_by_angle()
    return link(o)


def cone(name, r1, r2, depth, loc, m, rot=(0, 0, 0), verts=96):
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=mm(r1), radius2=mm(r2), depth=mm(depth))
    o = bpy.context.object
    o.name = name
    o.location = (mm(loc[0]), mm(loc[1]), mm(loc[2]))
    o.rotation_euler = rot
    o.data.materials.append(m)
    bpy.ops.object.shade_smooth_by_angle()
    return link(o)


def sphere(name, r, loc, m):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=mm(r), segments=48, ring_count=24)
    o = bpy.context.object
    o.name = name
    o.location = (mm(loc[0]), mm(loc[1]), mm(loc[2]))
    o.data.materials.append(m)
    bpy.ops.object.shade_smooth()
    return link(o)


FONT = None
for cand in (os.path.join(HERE, "..", "..", "tessera", "Tessera", "Fonts", "Switzer-Semibold.otf"),):
    if os.path.exists(cand):
        FONT = bpy.data.fonts.load(cand)


def text(name, s, size, loc, m, rot=(0, 0, 0), extrude=0.2, align="CENTER"):
    cu = bpy.data.curves.new(name, "FONT")
    cu.body = s
    cu.size = mm(size)
    cu.extrude = mm(extrude)
    cu.align_x = align
    cu.align_y = "CENTER"
    if FONT:
        cu.font = FONT
    o = bpy.data.objects.new(name, cu)
    o.location = (mm(loc[0]), mm(loc[1]), mm(loc[2]))
    o.rotation_euler = rot
    o.data.materials.append(m)
    bpy.context.scene.collection.objects.link(o)
    return link(o)


# ---------------------------------------------------------------- turntable

W, D = 406.0, 324.0                     # the maker's footprint
FOOT, RISER, SLAB = 8.0, 12.0, 22.0     # feet, the inset base, the slab: top at 42 mm
TOP = FOOT + RISER + SLAB

box("slab", (W, D, SLAB), (0, 0, FOOT + RISER + SLAB / 2), M["body"], bevel=4)
under = box("under", (W - 0.4, D - 0.4, RISER + 0.6), (0, 0, FOOT + RISER / 2 + 0.3), M["body"])
# chamfer only the bottom edges of the lower block: the plinth's undercut
import bmesh as _bm
_b = _bm.new(); _b.from_mesh(under.data)
_lay = _b.edges.layers.float.get("bevel_weight_edge") or _b.edges.layers.float.new("bevel_weight_edge")
for e in _b.edges:
    e[_lay] = 1.0 if all(v.co.z < 0 for v in e.verts) else 0.0
_b.to_mesh(under.data); _b.free()
_bv = under.modifiers.new("chamfer", "BEVEL")
_bv.width, _bv.segments, _bv.limit_method = mm(13), 1, "WEIGHT"
for sx in (-1, 1):
    for sy in (-1, 1):
        cyl(f"foot{sx}{sy}", 16, FOOT + 0.5, (sx * (W / 2 - 34), sy * (D / 2 - 30), FOOT / 2), M["rubber"], bevel=2)

# platter, mat, spindle: centred left of the middle, as on the real one
PC = (-42.0, 12.0)
PLAT_R, PLAT_H = 150.0, 17.0
cyl("platter", PLAT_R, PLAT_H, (PC[0], PC[1], TOP + PLAT_H / 2), M["plastic"], verts=192, bevel=1.5)
cyl("platter_hub", 24, 2.0, (PC[0], PC[1], TOP + PLAT_H + 1), M["plastic"], verts=64)
cyl("mat", 146, 2.2, (PC[0], PC[1], TOP + PLAT_H + 1.1), M["felt"], verts=192, bevel=0.6)
text("mat_logo", "gemini", 58, (PC[0], PC[1] + 10, TOP + PLAT_H + 2.25), M["white"], extrude=0.15)
cyl("spindle", 3.6, 15, (PC[0], PC[1], TOP + PLAT_H + 2 + 7.5), M["chrome"], verts=32, bevel=0.6)

# tonearm: round base at the rear right, a straight arm resting along the right
BASE = (150.0, 88.0)
cyl("arm_base", 23, 26, (BASE[0], BASE[1], TOP + 13), M["plastic"], bevel=2)
cyl("arm_collar", 15, 10, (BASE[0], BASE[1], TOP + 26 + 5), M["plastic"], bevel=1.5)
PIVOT = (BASE[0], BASE[1], TOP + 40.0)
cyl("arm_post", 6, 18, (BASE[0], BASE[1], TOP + 31 + 9), M["steel"], verts=32)
cyl("arm_bearing", 11, 12, (PIVOT[0], PIVOT[1], PIVOT[2]), M["plastic"], bevel=1.5)
TIP = (126.0, -74.0, TOP + 32.0)         # the headshell at rest, beside the platter's front right
d = Vector((mm(TIP[0] - PIVOT[0]), mm(TIP[1] - PIVOT[1]), mm(TIP[2] - PIVOT[2])))
L = d.length
mid = ((PIVOT[0] + TIP[0]) / 2, (PIVOT[1] + TIP[1]) / 2, (PIVOT[2] + TIP[2]) / 2)
yaw, pitch = math.atan2(d.y, d.x), math.acos(d.z / L)
cyl("arm_tube", 4.6, L * 1000, mid, M["plastic"], rot=(0, pitch, yaw), verts=32)
# the counter stub behind the pivot
back = (PIVOT[0] - 34 * math.cos(yaw), PIVOT[1] - 34 * math.sin(yaw), PIVOT[2] + 2)
cyl("arm_stub", 7, 40, ((PIVOT[0] + back[0]) / 2, (PIVOT[1] + back[1]) / 2, PIVOT[2] + 1), M["plastic"], rot=(0, math.pi / 2, yaw), verts=32, bevel=1)
# headshell and cartridge
hs = box("headshell", (34, 15, 9), (TIP[0] - 6 * math.cos(yaw), TIP[1] - 6 * math.sin(yaw), TIP[2] - 2), M["plastic"], bevel=1.2, rot=(0, 0, yaw))
box("cartridge", (18, 12, 6), (TIP[0] + 2 * math.cos(yaw), TIP[1] + 2 * math.sin(yaw), TIP[2] - 9), M["plastic"], bevel=0.8, rot=(0, 0, yaw))
box("cartridge_mark", (6, 12.2, 2), (TIP[0] + 8 * math.cos(yaw), TIP[1] + 8 * math.sin(yaw), TIP[2] - 9), M["red"], rot=(0, 0, yaw))
cyl("stylus", 0.5, 4, (TIP[0] + 9 * math.cos(yaw), TIP[1] + 9 * math.sin(yaw), TIP[2] - 13), M["chrome"], verts=12)
# arm rest and cue lever
cyl("armrest_post", 4, 26, (146, -30, TOP + 13), M["plastic"], verts=24)
box("armrest_clip", (14, 8, 10), (146, -30, TOP + 29), M["plastic"], bevel=1.5)
box("cue_lever", (22, 5, 4), (BASE[0] - 34, BASE[1] - 14, TOP + 30), M["plastic"], bevel=1, rot=(0, 0, -0.35))

# controls: speed, pitch, volume along the front right
for i, x in enumerate((104, 140, 176)):
    cyl(f"knob{i}", 7.5, 12, (x, -126, TOP + 6), M["plastic"], verts=48, bevel=1.2)
    box(f"knob_mark{i}", (1.2, 5, 0.6), (x, -126 - 4.5, TOP + 12.2), M["white"])
cyl("adapter", 12, 3, (-150, -128, TOP + 1.5), M["plastic"], verts=64, bevel=0.8)
text("brand", "gemini", 13, (-150, -112, TOP + 0.4), M["white"], extrude=0.1)

# rear panel, along the back face
BY = D / 2 + 0.5
box("autostop_sw", (10, 4, 5), (-140, BY, 22), M["plastic"], bevel=0.6)
cyl("rca_l", 5.5, 9, (-80, BY + 1, 22), M["white"], rot=(math.pi / 2, 0, 0), verts=32)
cyl("rca_r", 5.5, 9, (-62, BY + 1, 22), M["red"], rot=(math.pi / 2, 0, 0), verts=32)
box("spk_terminals", (62, 6, 16), (-8, BY, 22), M["plastic"], bevel=1)
for i, x in enumerate((-30, -16, 0, 14)):
    box(f"spk_clip{i}", (9, 3, 9), (x, BY + 3, 22), M["red"] if i % 2 else M["plastic"], bevel=0.8)
box("mode_sw", (12, 4, 6), (52, BY, 22), M["plastic"], bevel=0.6)
cyl("dc_jack", 4.5, 6, (80, BY + 1, 22), M["plastic"], rot=(math.pi / 2, 0, 0), verts=32)
box("power_sw", (18, 5, 11), (112, BY, 22), M["plastic"], bevel=1)
box("power_rocker", (14, 2, 8), (112, BY + 2.5, 22), M["plastic"], bevel=0.8)


# ---------------------------------------------------------------- speakers

SW, SD, SH = 127.0, 156.0, 203.0


def speaker(name, x, y):
    box(f"{name}_cab", (SW, SD, SH), (x, y, SH / 2), M["cabinet"], bevel=2.5)
    fy = y - SD / 2 - 0.6
    box(f"{name}_baffle", (SW - 6, 2, SH - 6), (x, fy, SH / 2), M["baffle"], bevel=1)
    # woofer: rubber surround, cone, dust cap
    cyl(f"{name}_ring", 41, 5, (x, fy - 2, 74), M["rubber"], rot=(math.pi / 2, 0, 0), verts=96, bevel=1.5)
    cone(f"{name}_cone", 36, 10, 16, (x, fy + 6, 74), M["cone"], rot=(-math.pi / 2, 0, 0))
    sphere(f"{name}_cap", 11, (x, fy - 3, 74), M["cone"])
    # tweeter in its diamond plate
    box(f"{name}_plate", (44, 3, 44), (x, fy - 1, 152), M["plastic"], bevel=2, rot=(0, math.pi / 4, 0))
    cyl(f"{name}_tweeter_ring", 12, 3, (x, fy - 3, 152), M["plastic"], rot=(math.pi / 2, 0, 0), verts=64, bevel=1)
    sphere(f"{name}_dome", 7.5, (x, fy - 2, 152), M["cone"])
    text(f"{name}_badge", "gemini", 7, (x, fy - 1.2, 16), M["white"] if BLACK else M["plastic"], rot=(math.pi / 2, 0, 0), extrude=0.1)
    # rear: port and terminals
    cyl(f"{name}_port", 14, 20, (x, y + SD / 2 - 8, 60), M["plastic"], rot=(math.pi / 2, 0, 0), verts=48)
    box(f"{name}_terminals", (36, 6, 22), (x, y + SD / 2 + 1, 130), M["plastic"], bevel=1)


speaker("spk_l", -(W / 2 + 62 + SW / 2), 24)
speaker("spk_r", W / 2 + 62 + SW / 2, 24)

# ---------------------------------------------------------------- studio

sc = bpy.context.scene
sc.render.engine = "CYCLES"
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.refresh_devices()
    for dv in prefs.devices:
        dv.use = True
    prefs.kernel_optimization_level = "OFF"
    sc.cycles.device = "GPU"
except Exception as exc:
    print("cycles gpu:", exc)
sc.cycles.samples = 160
sc.cycles.use_denoising = True
sc.view_settings.view_transform = "AgX"
sc.view_settings.look = "AgX - Base Contrast"
sc.render.film_transparent = False

bpy.ops.mesh.primitive_plane_add(size=6)
floor = bpy.context.object
floor.name = "floor"
floor.data.materials.append(M["floor"])
link(floor)
world = bpy.data.worlds.new("studio")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.85, 0.85, 0.86, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.28
sc.world = world


def area(name, loc, energy, size, target=None):
    ld = bpy.data.lights.new(name, "AREA")
    ld.energy, ld.size = energy, size
    o = bpy.data.objects.new(name, ld)
    sc.collection.objects.link(o)
    o.location = loc
    if target is not None:
        c = o.constraints.new("TRACK_TO")
        c.target, c.track_axis, c.up_axis = target, "TRACK_NEGATIVE_Z", "UP_Y"
    return o


aim = bpy.data.objects.new("aim", None)
sc.collection.objects.link(aim)
aim.location = (0, 0, mm(60))
area("key", (-0.9, -1.1, 1.3), 260, 1.6, aim)
area("fill", (1.3, -0.9, 0.9), 90, 2.0, aim)
area("rim", (0.3, 1.2, 1.0), 140, 1.2, aim)

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
sc.collection.objects.link(cam)
sc.camera = cam
c = cam.constraints.new("TRACK_TO")
c.target, c.track_axis, c.up_axis = aim, "TRACK_NEGATIVE_Z", "UP_Y"


def render(name, loc, lens, ortho=None, res=(1800, 1125), rot=None):
    cam.data.type = "ORTHO" if ortho else "PERSP"
    if ortho:
        cam.data.ortho_scale = ortho
    cam.data.lens = lens
    cam.location = loc
    # a fixed orientation (the top view) instead of tracking the aim
    c.influence = 0.0 if rot else 1.0
    if rot:
        cam.rotation_euler = rot
    sc.render.resolution_x, sc.render.resolution_y = res
    sc.render.image_settings.file_format = "PNG"
    sc.render.filepath = os.path.join(OUT, f"tt900-{FINISH}-{name}.png")
    bpy.ops.render.render(write_still=True)


render("hero", (-0.5, -1.08, 0.56), 52)
render("front", (0, -3.0, mm(60)), 50, ortho=0.95)
render("top", (0, 0, 3.0), 50, ortho=0.95, res=(1800, 1400), rot=(0, 0, 0))
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, f"tt900-{FINISH}.blend"))
try:
    bpy.ops.export_scene.gltf(filepath=os.path.join(HERE, f"tt900-{FINISH}.glb"), export_format="GLB", use_selection=False)
except Exception as exc:
    print("gltf:", exc)
print("done", FINISH)
